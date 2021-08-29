//
//  Unhide.mm
//
//  Created by John Holdsworth on 07/03/2021.
//
//  Removes "hidden" visibility for certain Swift symbols
//  (default argument generators) so they can be referenced
//  in a file being dynamically loaded.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/Unhide.mm#19 $
//

#import <Foundation/Foundation.h>

#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach-o/stab.h>
#import <sys/stat.h>
#import <string>
#import <map>

extern "C" {
    #import "InjectionClient.h"
}

static std::map<std::string,int> seen;

void unhide_reset(void) {
    seen.clear();
}

int unhide_symbols(const char *framework, const char *linkFileList, FILE *log, time_t since) {
    FILE *linkFiles = fopen(linkFileList, "r");
    if (!linkFiles) {
       fprintf(log, "unhide: Could not open link file list %s\n", linkFileList);
       return -1;
    }

    char buffer[PATH_MAX];
    int totalExported = 0;

    while (fgets(buffer, sizeof buffer, linkFiles)) {
        buffer[strlen(buffer)-1] = '\000';

        @autoreleasepool {
//            struct stat info;
//            if (stat(buffer, &info) || info.st_mtimespec.tv_sec < since)
//                continue;
            NSString *file = [NSString stringWithUTF8String:buffer];
            NSData *patched = [[NSMutableData alloc] initWithContentsOfFile:file];

            if (!patched) {
                fprintf(log, "unhide: Could not read %s\n", [file UTF8String]);
                continue;
            }

            struct mach_header_64 *object = (struct mach_header_64 *)[patched bytes];
            const char *filename = file.lastPathComponent.UTF8String;

            if (object->magic != MH_MAGIC_64) {
                fprintf(log, "unhide: Invalid magic 0x%x != 0x%x (bad arch?)\n",
                        object->magic, MH_MAGIC_64);
                continue;
            }

            struct symtab_command *symtab = NULL;
            struct dysymtab_command *dylib = NULL;

            for (struct load_command *cmd = (struct load_command *)((char *)object + sizeof *object) ;
                 cmd < (struct load_command *)((char *)object + object->sizeofcmds) ;
                 cmd = (struct load_command *)((char *)cmd + cmd->cmdsize)) {

                if (cmd->cmd == LC_SYMTAB)
                    symtab = (struct symtab_command *)cmd;
                else if (cmd->cmd == LC_DYSYMTAB)
                    dylib = (struct dysymtab_command *)cmd;
            }

            if (!symtab || !dylib) {
                fprintf(log, "unhide: Missing symtab or dylib cmd %s: %p & %p\n",
                        filename, symtab, dylib);
                continue;
            }
            struct nlist_64 *all_symbols64 = (struct nlist_64 *)((char *)object + symtab->symoff);
#if 1
            struct nlist_64 *end_symbols64 = all_symbols64 + symtab->nsyms;
            int exported = 0;

//            dylib->iextdefsym -= dylib->nlocalsym;
//            dylib->nextdefsym += dylib->nlocalsym;
//            dylib->nlocalsym = 0;
#endif
            for (int i=0 ; i<symtab->nsyms ; i++) {
                struct nlist_64 &symbol = all_symbols64[i];
                if (symbol.n_sect == NO_SECT)
                    continue; // not definition
                const char *symname = (char *)object + symtab->stroff + symbol.n_un.n_strx;

//                printf("symbol: #%d 0%lo 0x%x 0x%x %3d %s\n", i,
//                       (char *)&symbol.n_type - (char *)object,
//                       symbol.n_type, symbol.n_desc,
//                       symbol.n_sect, symname);
                if (strncmp(symname, "_$s", 3) != 0)
                    continue; // not swift symbol

                // Default argument generators have a suffix ANN_
                // Covers a few other cases encountred now as well.
                const char *symend = symname + strlen(symname) - 1;
                BOOL isDefaultArgument = (*symend == '_' &&
                    (symend[-1] == 'A' || (isdigit(symend[-1]) &&
                    (symend[-2] == 'A' || (isdigit(symend[-2]) &&
                     symend[-3] == 'A'))))) || strcmp(symend-2, "vau") == 0 ||
                    strcmp(symend-1, "FZ") == 0 || (symend[-1] == 'M' && (
                    *symend == 'c' || *symend == 'g' || *symend == 'n'));

                // The following reads: If symbol is for a default argument
                // and it is the definition (not a reference) and we've not
                // seen it before and it hadsn't already been "unhidden"...
                if (isDefaultArgument && !seen[symname]++ &&
                    symbol.n_type & N_PEXT) {
                    symbol.n_type |= N_EXT;
                    symbol.n_type &= ~N_PEXT;
                    symbol.n_type = 0xf;
                    symbol.n_desc = N_GSYM;

                    if (!exported++)
                        fprintf(log, "%s.%s: local: %d %d ext: %d %d undef: %d %d extref: %d %d indirect: %d %d extrel: %d %d localrel: %d %d symlen: 0%lo\n",
                               framework, filename,
                               dylib->ilocalsym, dylib->nlocalsym,
                               dylib->iextdefsym, dylib->nextdefsym,
                               dylib->iundefsym, dylib->nundefsym,
                               dylib->extrefsymoff, dylib->nextrefsyms,
                               dylib->indirectsymoff, dylib->nindirectsyms,
                               dylib->extreloff, dylib->nextrel,
                               dylib->locreloff, dylib->nlocrel,
                               (char *)&end_symbols64->n_un - (char *)object);

                    fprintf(log, "exported: #%d 0%lo 0x%x 0x%x %3d %s\n", i,
                           (char *)&symbol.n_type - (char *)object,
                           symbol.n_type, symbol.n_desc,
                           symbol.n_sect, symname);
                }
            }

            if (exported && ![patched writeToFile:file atomically:YES])
                fprintf(log, "unhide: Could not write %s\n", [file UTF8String]);
            totalExported += exported;
        }
    }

    fclose(linkFiles);
    return totalExported;
}

int unhide_framework(const char *framework, FILE *log) {
    int totalExported = 0;
#if 0 // Not implemented
    @autoreleasepool {
        NSString *file = [NSString stringWithUTF8String:framework];
        NSData *patched = [[NSMutableData alloc] initWithContentsOfFile:file];

        if (!patched) {
            fprintf(log, "unhide: Could not read %s\n", [file UTF8String]);
            return -1;
        }

        struct mach_header_64 *object = (struct mach_header_64 *)[patched bytes];
        const char *filename = file.lastPathComponent.UTF8String;

        if (object->magic != MH_MAGIC_64) {
            fprintf(log, "unhide: Invalid magic 0x%x != 0x%x (bad arch?)\n",
                    object->magic, MH_MAGIC_64);
            return -1;
        }

        struct symtab_command *symtab = NULL;
        struct dysymtab_command *dylib = NULL;

        for (struct load_command *cmd = (struct load_command *)((char *)object + sizeof *object) ;
             cmd < (struct load_command *)((char *)object + object->sizeofcmds) ;
             cmd = (struct load_command *)((char *)cmd + cmd->cmdsize)) {

            if (cmd->cmd == LC_SYMTAB)
                symtab = (struct symtab_command *)cmd;
            else if (cmd->cmd == LC_DYSYMTAB)
                dylib = (struct dysymtab_command *)cmd;
        }

        if (!symtab || !dylib) {
            fprintf(log, "unhide: Missing symtab or dylib cmd %s: %p & %p\n",
                    filename, symtab, dylib);
            return -1;
        }
        struct nlist_64 *all_symbols64 = (struct nlist_64 *)((char *)object + symtab->symoff);
#if 1
        struct nlist_64 *end_symbols64 = all_symbols64 + symtab->nsyms;
        int exported = 0;

//            dylib->iextdefsym -= dylib->nlocalsym;
//            dylib->nextdefsym += dylib->nlocalsym;
//            dylib->nlocalsym = 0;
#endif
        for (int i=0 ; i<symtab->nsyms ; i++) {
            struct nlist_64 &symbol = all_symbols64[i];
            if (symbol.n_sect == NO_SECT)
                continue; // not definition
            const char *symname = (char *)object + symtab->stroff + symbol.n_un.n_strx;

//                printf("symbol: #%d 0%lo 0x%x 0x%x %3d %s\n", i,
//                       (char *)&symbol.n_type - (char *)object,
//                       symbol.n_type, symbol.n_desc,
//                       symbol.n_sect, symname);
            if (strncmp(symname, "_$s", 3) != 0)
                continue; // not swift symbol

            // Default argument generators have a suffix ANN_
            // Covers a few other cases encountred now as well.
            const char *symend = symname + strlen(symname) - 1;
            BOOL isDefaultArgument = (*symend == '_' &&
                (symend[-1] == 'A' || (isdigit(symend[-1]) &&
                (symend[-2] == 'A' || (isdigit(symend[-2]) &&
                 symend[-3] == 'A'))))) || strcmp(symend-2, "vau") == 0 ||
                strcmp(symend-1, "FZ") == 0 || (symend[-1] == 'M' && (
                *symend == 'c' || *symend == 'g' || *symend == 'n'));

            // The following reads: If symbol is for a default argument
            // and it is the definition (not a reference) and we've not
            // seen it before and it hadsn't already been "unhidden"...
            if (isDefaultArgument && !seen[symname]++ &&
                symbol.n_type & N_PEXT) {
                symbol.n_type |= N_EXT;
                symbol.n_type &= ~N_PEXT;
                symbol.n_type = 0xf;
                symbol.n_desc = N_GSYM;

                if (!exported++)
                    fprintf(log, "%s.%s: local: %d %d ext: %d %d undef: %d %d extref: %d %d indirect: %d %d extrel: %d %d localrel: %d %d symlen: 0%lo\n",
                           framework, filename,
                           dylib->ilocalsym, dylib->nlocalsym,
                           dylib->iextdefsym, dylib->nextdefsym,
                           dylib->iundefsym, dylib->nundefsym,
                           dylib->extrefsymoff, dylib->nextrefsyms,
                           dylib->indirectsymoff, dylib->nindirectsyms,
                           dylib->extreloff, dylib->nextrel,
                           dylib->locreloff, dylib->nlocrel,
                           (char *)&end_symbols64->n_un - (char *)object);

                fprintf(log, "exported: #%d 0%lo 0x%x 0x%x %3d %s\n", i,
                       (char *)&symbol.n_type - (char *)object,
                       symbol.n_type, symbol.n_desc,
                       symbol.n_sect, symname);
            }
        }

        if (exported && ![patched writeToFile:file atomically:YES])
            fprintf(log, "unhide: Could not write %s\n", [file UTF8String]);
        totalExported += exported;
    }
#endif
    return totalExported;
}
