#include <utf8proc.h>

int nd_char_width(int codepoint, int ambiguous_double) {
    const utf8proc_property_t *p = utf8proc_get_property(codepoint);
    return ambiguous_double && p->ambiguous_width ? 2 : utf8proc_charwidth(codepoint);
}
int nd_grapheme_break(int previous, int current, int *state) {
    return utf8proc_grapheme_break_stateful(previous, current, state);
}
