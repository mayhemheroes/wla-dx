
#ifndef _INCLUDE_H
#define _INCLUDE_H

int include_file(char *name, int *include_size, char *namespace);
int incbin_file(char *name, int *id, int *swap, int *skip, int *read, struct macro_static **macro);
int preprocess_file(char *c, char *d, char *o, int *s, char *f);
int create_full_name(char *dir, char *name);
int print_file_names(void);
char *get_file_name(int id);

#endif
