/* terminal.c */
void ex_terminal(exarg_T *eap);
void free_terminal(buf_T *buf);
void write_to_term(buf_T *buffer, char_u *msg, channel_T *channel);
int terminal_loop(void);
void term_channel_closed(channel_T *ch);
int term_update_window(win_T *wp);
int term_is_finished(buf_T *buf);
void term_change_in_curbuf(void);
int term_get_attr(buf_T *buf, linenr_T lnum, int col);
char_u *term_get_status_text(term_T *term);
int set_ref_in_term(int copyID);
/* vim: set ft=c : */
