#include "pmh_parser.h"
#include <assert.h>
#include <stdio.h>

static void check(char *text, pmh_element_type expected) {
    pmh_element **elements = NULL;
    pmh_markdown_to_elements(text, pmh_EXT_NONE, &elements);
    assert(elements != NULL);
    pmh_sort_elements_by_pos(elements);
    assert(elements[expected] != NULL);
    for (int type = 0; type < pmh_NUM_LANG_TYPES; type++) {
        unsigned long previous = 0;
        for (pmh_element *element = elements[type]; element; element = element->next) {
            assert(element->pos <= element->end);
            assert(element->pos >= previous);
            previous = element->pos;
        }
    }
    pmh_free_elements(elements);
}

int main(void) {
    for (int i = 0; i < 100; i++) {
        check("# Heading\n\nHello **world**.\n", pmh_H1);
        check("😀 café 漢字 **bold** and [link](https://example.com)\n", pmh_STRONG);
        check("Paragraph\n\n    code();\n", pmh_VERBATIM);
    }
    puts("Portable parser checks passed (300 parses, including Unicode).");
    return 0;
}
