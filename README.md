# vimgit

vimgit is vim with a word index of your source code. In one keystroke it finds
every file using a word, the definition of a routine, a module or a type, or a
file from its name, across one or several git repositories. It was written for
Fortran codes such as IAL (ARPEGE/IFS/ALADIN) and the libraries of their
bundles, and also indexes C and C++.

## Requirements

- vim compiled with Perl (`vim --version | grep +perl`);
- git: `/bin/git`, or the one given by the environment variable `GITVIMGIT`
  (for example `export GITVIMGIT=$HOME/install/git/bin/git`);
- Perl modules `DB_File` and `local::lib`; for the transforms (`:T`), also
  `XML::LibXML`, `XML::XPath`, `List::MoreUtils`, and
  [fxtran](https://github.com/pmarguinaud/fxtran) with its Perl module.

`vimgit` can be run through a symbolic link (for example from `~/bin`).

## Quick start

In a git repository:

```
vimgit -i          # build the index (once per commit; incremental changes are followed)
vimgit cpg.F90     # open a file by its name, from anywhere in the repository
```

In a directory holding several repositories (an ecbundle `source/` directory):

```
cd source
vimgit -i          # writes .vimgit/config listing the repositories, then indexes them
vimgit
```

## Starting vimgit

```
vimgit [options] [file ...]
```

Files can be given by name (`cpg.F90`), by path (`../adiab/cpg.F90`), with a
line (`cpg.F90:120`, `cpg.F90(120)`) and a column (`cpg.F90:120.8`). When a
name matches several files, vimgit asks which one to open.

| Option | |
|---|---|
| `-i [repo ...]` | build the missing indexes (of all repositories, or of those named) |
| `-I [repo ...]` | build the indexes again, even if they exist |
| `-j N` | indexes built at the same time (default 4) |
| `-v` | log to `.vimgit/log`; with `-i`/`-I`, list the indexed files |
| `-g` | run gvim |
| `-b` | read a backtrace (Intel, DrHook, EC_DRHOOK) on the standard input or from the files given, and open each location |

## Workspace

vimgit works in a *workspace*:

1. the directory holding `.vimgit/config`, looking upward from the current
   directory;
2. otherwise, the git repository containing the current directory;
3. otherwise, the current directory: vimgit lists the git repositories it
   contains (symbolic links followed; aliases and links into a repository
   skipped) and writes `.vimgit/config`.

vim runs at the top of the workspace; files are shown as `<repo>/<path>`.

### `.vimgit/config`

```
repo ial-source                 # a repository; results follow the order of these lines
repo fiat
repo surfex

exclude fxtran-acdc tests/**   # files of a repository not to index (gitignore pattern,
                               # relative to the top of the repository)

index *.F90 *.F *.h            # names of the files to index (any case), instead of
                               # *.f90 *.f *.c *.cc *.cpp *.h *.hpp

blacklist DR_HOOK MPL_*        # routines left out of call trees (any case, * allowed)
```

Repositories not listed are ignored. Lines naming an alias, a sub-directory or
something that is not a repository are reported and ignored.

A `.vimgitignore` file (gitignore syntax) in any directory of a repository also
excludes files, for everyone using vimgit on that repository. An `exclude` line
of the config wins over a `!` line of a `.vimgitignore`.

Excluded files never appear in results or in the list of files to choose from;
they can still be opened by their path. After changing exclusions or `index`,
run `vimgit -I`.

## Indexes

Each repository has its own index, in `.git/vimgit/<commit>/`, built for its
current commit by `vimgit -i`. The 3 most recent indexes of a repository are
kept.

Besides words and file names, the index records, for Fortran files, the
routines each file defines (subroutines, functions, programs; not interface
blocks) and the routines each one calls (`CALL` statements). Call trees and
the definition key use them. Indexes built by older versions of vimgit lack
them: `vimgit -i` builds them again.

An index stays usable while you work: at the first search, the files changed
since its commit (committed, modified, untracked) are scanned again; a file
written in vim is scanned again at once; when HEAD moves (commit, checkout,
pull), this is done again. `:R` forces it, for changes made outside vim.
An index built for one of the last 10 commits is used; for older ones, run
`vimgit -i`.

A repository without an index is reported at start and searched with
`git grep` (slower).

## In vim

| Key / command | |
|---|---|
| `<TAB>` | search the word under the cursor; in a result buffer, open the file or line under the cursor, or the next page on `<<<< >>>>` |
| `<S-TAB>` | same, in a new window |
| `` ` ``, `²`, `œ` | go to the definition of the routine (`CALL x`, `#include "x.intfb.h"`), module (`USE x`), type (`TYPE (x)`, `CLASS (x)`) under the cursor; on `%x`, list the lines using component `x`; a routine with several definitions gives a list to choose from, the most likely first |
| `<C-²>` | same, in a new window |
| `<BS>` | go back |
| `:F word` | search a word in all repositories |
| `:FR word` | search a word in the repository of the current buffer |
| `:E file` | open a file, as on the command line |
| `:R` | rescan changed files (after changes made outside vim) |
| `:CT [name [depth]]` | call tree of a routine (the word under the cursor without a name): the routines it calls, and so on |
| `:CTR [name [depth]]` | tree of the routines calling it |
| `:T align_args`, `:T align_use` | align the declarations of dummy arguments; clean up and align `USE` statements (needs fxtran) |
| `:C` | make the current file a single link (done before each write) |

Results show 200 files at a time; `<TAB>` on the `<<<< >>>>` line at the end
shows the next ones. When a definition is found in a single file, vimgit opens
it directly.

## Call trees

`:CT cpg` writes `.vimgit/calltree=/cpg.txt` and opens it:

```
CPG
├── YDCPG_SL2%SET (type-bound)
├── CPG_GP_TENC
│   ├── ABOR1 [+9]
│   └── ETENC [+1]
│       ├── ABOR1 (see line 4)
│       ├── SUESC2R
│       │   └── ABOR1 (see line 4)
│       └── GPCOUPL
...
```

- one routine per line, drawn with lines; the definitions are kept next to the
  tree (`cpg.loc`), for `²`;
- a routine is expanded once; later, `(see line N)`, or `(recursive, see line N)`;
- `[+n]`: other definitions exist; the one shown is, in this order, in the
  caller's file, in the caller's repository, in a file named after the
  routine, in the first repository of the config; routines contained in
  another file (after `CONTAINS`) come last;
- `(not found)`: no definition in the indexed repositories;
  `(type-bound)`: `CALL x%y`, shown but not followed;
- `blacklist` names of the config are left out; `:CT cpg 3` stops at 3 levels
  (`...` marks routines not expanded).

In a tree, `<TAB>` on a name searches it, `²` opens its definition (a list for
`[+n]`); on `(see line N)`, both go to line N. `zc`, `zo`, `zM`, `zR` fold and
unfold (folding by depth). `:CTR rain_ice` shows the routines calling `RAIN_ICE` the same
way.

Only `CALL` statements are seen, not function calls; a call whose name is on a
continuation line (`CALL &` / `& NAME`) is missed.

`~/.vimgit.rc` is sourced at start, for your own vim settings.
