/* vi:set ts=8 sts=4 sw=4 noet:
 *
 * VIM - Vi IMproved	by Bram Moolenaar
 *			Visual Workshop integration by Gordon Prieur
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#include "vim.h"

#if defined(FEAT_BEVAL) || defined(PROTO)

/*
 * Get the text and position to be evaluated for "beval".
 * If "getword" is true the returned text is not the whole line but the
 * relevant word in allocated memory.
 * Returns OK or FAIL.
 */
    int
get_beval_info(
    BalloonEval	*beval,
    int		getword,
    win_T	**winp,
    linenr_T	*lnump,
    char_u	**textp,
    int		*colp)
{
    win_T	*wp;
    int		row, col;
    char_u	*lbuf;
    linenr_T	lnum;

    *textp = NULL;
# ifdef FEAT_BEVAL_TERM
#  ifdef FEAT_GUI
    if (!gui.in_use)
#  endif
    {
	row = mouse_row;
	col = mouse_col;
    }
# endif
# ifdef FEAT_GUI
    if (gui.in_use)
    {
	row = Y_2_ROW(beval->y);
	col = X_2_COL(beval->x);
    }
#endif
    wp = mouse_find_win(&row, &col);
    if (wp != NULL && row >= 0 && row < wp->w_height && col < wp->w_width)
    {
	/* Found a window and the cursor is in the text.  Now find the line
	 * number. */
	if (!mouse_comp_pos(wp, &row, &col, &lnum))
	{
	    /* Not past end of the file. */
	    lbuf = ml_get_buf(wp->w_buffer, lnum, FALSE);
	    if (col <= win_linetabsize(wp, lbuf, (colnr_T)MAXCOL))
	    {
		/* Not past end of line. */
		if (getword)
		{
		    /* For Netbeans we get the relevant part of the line
		     * instead of the whole line. */
		    int		len;
		    pos_T	*spos = NULL, *epos = NULL;

		    if (VIsual_active)
		    {
			if (LT_POS(VIsual, curwin->w_cursor))
			{
			    spos = &VIsual;
			    epos = &curwin->w_cursor;
			}
			else
			{
			    spos = &curwin->w_cursor;
			    epos = &VIsual;
			}
		    }

		    col = vcol2col(wp, lnum, col);

		    if (VIsual_active
			    && wp->w_buffer == curwin->w_buffer
			    && (lnum == spos->lnum
				? col >= (int)spos->col
				: lnum > spos->lnum)
			    && (lnum == epos->lnum
				? col <= (int)epos->col
				: lnum < epos->lnum))
		    {
			/* Visual mode and pointing to the line with the
			 * Visual selection: return selected text, with a
			 * maximum of one line. */
			if (spos->lnum != epos->lnum || spos->col == epos->col)
			    return FAIL;

			lbuf = ml_get_buf(curwin->w_buffer, VIsual.lnum, FALSE);
			len = epos->col - spos->col;
			if (*p_sel != 'e')
			    len += MB_PTR2LEN(lbuf + epos->col);
			lbuf = vim_strnsave(lbuf + spos->col, len);
			lnum = spos->lnum;
			col = spos->col;
		    }
		    else
		    {
			/* Find the word under the cursor. */
			++emsg_off;
			len = find_ident_at_pos(wp, lnum, (colnr_T)col, &lbuf,
					FIND_IDENT + FIND_STRING + FIND_EVAL);
			--emsg_off;
			if (len == 0)
			    return FAIL;
			lbuf = vim_strnsave(lbuf, len);
		    }
		}

		*winp = wp;
		*lnump = lnum;
		*textp = lbuf;
		*colp = col;
#ifdef FEAT_VARTABS
		if (beval->vts)
		    vim_free(beval->vts);
		beval->vts = tabstop_copy(wp->w_buffer->b_p_vts_array);
#endif
		beval->ts = wp->w_buffer->b_p_ts;
		return OK;
	    }
	}
    }

    return FAIL;
}

/*
 * Show a balloon with "mesg" or "list".
 */
    void
post_balloon(BalloonEval *beval UNUSED, char_u *mesg, list_T *list UNUSED)
{
# ifdef FEAT_BEVAL_TERM
#  ifdef FEAT_GUI
    if (!gui.in_use)
#  endif
	ui_post_balloon(mesg, list);
# endif
# ifdef FEAT_BEVAL_GUI
    if (gui.in_use)
	/* GUI can't handle a list */
	gui_mch_post_balloon(beval, mesg);
# endif
}

/*
 * Returns TRUE if the balloon eval has been enabled:
 * 'ballooneval' for the GUI and 'balloonevalterm' for the terminal.
 * Also checks if the screen isn't scrolled up.
 */
    int
can_use_beval(void)
{
    return (0
#ifdef FEAT_BEVAL_GUI
		|| (gui.in_use && p_beval)
#endif
#ifdef FEAT_BEVAL_TERM
		|| (
# ifdef FEAT_GUI
		    !gui.in_use &&
# endif
		    p_bevalterm)
#endif
	     ) && msg_scrolled == 0;
}

/*
 * Common code, invoked when the mouse is resting for a moment.
 */
    void
general_beval_cb(BalloonEval *beval, int state UNUSED)
{
#ifdef FEAT_EVAL
    win_T	*wp;
    int		col;
    int		use_sandbox;
    linenr_T	lnum;
    char_u	*text;
    static char_u  *result = NULL;
    long	winnr = 0;
    char_u	*bexpr;
    buf_T	*save_curbuf;
    size_t	len;
    win_T	*cw;
#endif
    static int	recursive = FALSE;

    /* Don't do anything when 'ballooneval' is off, messages scrolled the
     * windows up or we have no beval area. */
    if (!can_use_beval() || beval == NULL)
	return;

    /* Don't do this recursively.  Happens when the expression evaluation
     * takes a long time and invokes something that checks for CTRL-C typed. */
    if (recursive)
	return;
    recursive = TRUE;

#ifdef FEAT_EVAL
    if (get_beval_info(beval, TRUE, &wp, &lnum, &text, &col) == OK)
    {
	bexpr = (*wp->w_buffer->b_p_bexpr == NUL) ? p_bexpr
						    : wp->w_buffer->b_p_bexpr;
	if (*bexpr != NUL)
	{
	    /* Convert window pointer to number. */
	    for (cw = firstwin; cw != wp; cw = cw->w_next)
		++winnr;

	    set_vim_var_nr(VV_BEVAL_BUFNR, (long)wp->w_buffer->b_fnum);
	    set_vim_var_nr(VV_BEVAL_WINNR, winnr);
	    set_vim_var_nr(VV_BEVAL_WINID, wp->w_id);
	    set_vim_var_nr(VV_BEVAL_LNUM, (long)lnum);
	    set_vim_var_nr(VV_BEVAL_COL, (long)(col + 1));
	    set_vim_var_string(VV_BEVAL_TEXT, text, -1);
	    vim_free(text);

	    /*
	     * Temporarily change the curbuf, so that we can determine whether
	     * the buffer-local balloonexpr option was set insecurely.
	     */
	    save_curbuf = curbuf;
	    curbuf = wp->w_buffer;
	    use_sandbox = was_set_insecurely((char_u *)"balloonexpr",
				 *curbuf->b_p_bexpr == NUL ? 0 : OPT_LOCAL);
	    curbuf = save_curbuf;
	    if (use_sandbox)
		++sandbox;
	    ++textlock;

	    vim_free(result);
	    result = eval_to_string(bexpr, NULL, TRUE);

	    /* Remove one trailing newline, it is added when the result was a
	     * list and it's hardly ever useful.  If the user really wants a
	     * trailing newline he can add two and one remains. */
	    if (result != NULL)
	    {
		len = STRLEN(result);
		if (len > 0 && result[len - 1] == NL)
		    result[len - 1] = NUL;
	    }

	    if (use_sandbox)
		--sandbox;
	    --textlock;

	    set_vim_var_string(VV_BEVAL_TEXT, NULL, -1);
	    if (result != NULL && result[0] != NUL)
	    {
		post_balloon(beval, result, NULL);
		recursive = FALSE;
		return;
	    }
	}
    }
#endif
#ifdef FEAT_NETBEANS_INTG
    if (bevalServers & BEVAL_NETBEANS)
	netbeans_beval_cb(beval, state);
#endif
#ifdef FEAT_SUN_WORKSHOP
    if (bevalServers & BEVAL_WORKSHOP)
	workshop_beval_cb(beval, state);
#endif

    recursive = FALSE;
}

#endif

