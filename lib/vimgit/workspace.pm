package vimgit::workspace;

# the directory vimgit works in, and its git repositories:
# - a directory holding .vimgit/config, which lists the repositories (repo <mount>),
#   in the order used for search results;
# - or the top of a git repository, alone (mounted at '.'), when there is no config
# ~/.vimgit/config applies to both (vimgit::config)

use strict;

use Cwd qw ();
use File::Basename;
use File::Path;
use File::Spec;
use FileHandle;

use vimgit::config;
use vimgit::dir;
use vimgit::git;
use vimgit::lang;
use vimgit::repo;

sub findroot
{

# directory holding .vimgit/config, looking upward from $dir; undef if none

  my ($class, $dir) = @_;

  $dir = &Cwd::abs_path ($dir);

  while (1)
    {
      return $dir if (-f "$dir/.vimgit/config");
      last if ($dir eq '/');
      $dir = &dirname ($dir);
    }

  return undef;
}

sub new
{

# root : absolute path of the workspace; it holds .vimgit/config, or is the top of a repository

  my ($class, %args) = @_;

  my $self = bless { root => $args{root}, repos => [], warnings => [] }, $class;

  my $c = $self->{config} = 'vimgit::config'->load (root => $self->{root});

  $self->warning ($_) for (@{ $c->{warnings} });
  $self->warning ("$_ uses the old format; vimgit -c prints it in the new one") for (@{ $c->{old} });

  'vimgit::git'->setpath ($c->value ('git'));

  if (-f "$self->{root}/.vimgit/config")
    {
      $self->readconfig ();
    }
  else
    {
      push @{ $self->{repos} }, 'vimgit::repo'->new (top => $self->{root}, mount => '.');
    }

  $self->settings_ ();

  return $self;
}

sub warning
{
  my ($self, $msg) = @_;
  push @{ $self->{warnings} }, $msg;
}

sub readconfig
{

# the repositories and directories listed by the repo and dir settings of .vimgit/config,
# in their order

  my $self = shift;

  my %seen; # top -> mount

  for my $m ($self->{config}->members ())
    {
      if (defined ($m->[2]))
        {
          $self->adddir_ (@$m, \%seen);
          next;
        }

      my $mount = 'File::Spec'->canonpath ($m->[0]);
      my $dir = "$self->{root}/$mount";

      my $top = (-d $dir) ? 'vimgit::git'->getTopDirectory (dir => $dir) : '';

      if (! $top)
        {
          $self->warning ("$mount is not a git repository; ignored");
        }
      elsif (&Cwd::abs_path ($dir) ne &Cwd::abs_path ($top))
        {
          $self->warning ("$mount is not the top of a git repository; ignored");
        }
      elsif (my $other = $seen{&Cwd::abs_path ($top)})
        {
          $self->warning ("$mount is the same repository as $other; ignored");
        }
      else
        {
          $seen{&Cwd::abs_path ($top)} = $mount;
          push @{ $self->{repos} }, 'vimgit::repo'->new (top => &Cwd::abs_path ($top), mount => $mount);
        }
    }

  $self->warning (".vimgit/config lists no repository") unless (@{ $self->{repos} });

# a directory inside a repository or another directory, or holding one : its files would
# be indexed twice

  my @top = map { [ $_->{mount}, $_->{top}, $_->isa ('vimgit::dir') ] } $self->repos ();
  for my $d (grep { $_->isa ('vimgit::dir') } $self->repos ())
    {
      for my $t (grep { $_->[0] ne $d->{mount} } @top)
        {
          if (index ("$d->{top}/", "$t->[1]/") == 0)
            {
              $self->warning ("dir $d->{mount} is inside $t->[0]; its files are indexed twice");
            }
          elsif ((! $t->[2]) && (index ("$t->[1]/", "$d->{top}/") == 0))
            {
              $self->warning ("dir $d->{mount} holds $t->[0]; its files are indexed twice");
            }
        }
    }
}

sub adddir_
{

# directory $name => $path (dir setting, line $origin); seen : top -> mount

  my ($self, $name, $origin, $path, $seen) = @_;

  my $abs = 'File::Spec'->rel2abs ($path, $self->{root});

  if (! -d $abs)
    {
      $self->warning ("$origin: dir $name: $path is not a directory; ignored");
      return;
    }

  my $top = &Cwd::abs_path ($abs);

  if (my $other = $seen->{$top})
    {
      $self->warning ("$origin: dir $name: $path is the same as $other; ignored");
    }
  elsif ($self->repo ($name))
    {
      $self->warning ("$origin: dir $name: $name is already the name of a repository or a directory; ignored");
    }
  elsif (-e "$self->{root}/$name")
    {
      $self->warning ("$origin: dir $name: $name is a file or directory of the workspace; choose another name; ignored");
    }
  else
    {
      $seen->{$top} = $name;
      push @{ $self->{repos} }, 'vimgit::dir'->new (top => $top, mount => $name);
      $self->warning ("$origin: dir $name: $path is not writable; it has no index")
        unless (-w $top);
    }
}

sub realpath
{

# path to open for workspace path $f : the real path for the files of a directory (dir),
# $f otherwise

  my ($self, $f) = @_;
  my ($name, $rel) = ($f =~ m,^([^/]+)/(.*)$,o) or return $f;
  my $d = $self->repo ($name);
  return ($d && $d->isa ('vimgit::dir')) ? $d->realpath ($rel) : $f;
}

sub readonly
{

# true if workspace path $f is a file of a directory (dir) not listed by readwrite

  my ($self, $f) = @_;
  my ($repo) = $self->repo_of ($f) or return 0;
  return 0 unless ($repo->isa ('vimgit::dir'));
  return ! grep { $_ eq $repo->{mount} } $self->{config}->readwrite ();
}

sub settings_
{

# settings applying to the repositories : exclude, index, blacklist, keep

  my $self = shift;

  my $c = $self->{config};

# exclude <repo> => <pattern> : gitignore pattern, relative to the top of the repository;
# <repo> is a mount name; for a workspace made of one repository, the name of its directory

  for my $x (@{ $c->{exclude} })
    {
      my ($mount, $pattern, $origin, $scope) = @$x;
      my ($repo) = grep { ($_->{mount} eq 'File::Spec'->canonpath ($mount))
                       || (($_->{mount} eq '.') && (&basename ($_->{top}) eq $mount)) } $self->repos ();
      if ($repo)
        {
          push @{ $repo->{exclude} }, $pattern;
        }
      elsif ($scope eq 'workspace')
        {
          $self->warning ("$origin: exclude $mount: $mount is not a repository of the workspace");
        }
    }

# index <glob> ... : names of the files to index, instead of the default list

  'vimgit::lang'->setindexed ($c->indexed ()) if ($c->indexed ());

# blacklist <name> ... : routines left out of call trees; any case, * for any characters

  if (my @blacklist = $c->blacklist ())
    {
      my $re = join ('|', map { (my $g = quotemeta (lc ($_))) =~ s/\\\*/\\w*/go; $g } @blacklist);
      $self->{blacklist} = qr/^(?:$re)$/i;
    }

  $_->{keep} = $c->value ('keep') for ($self->repos ());

# readwrite <name> ... : directories whose files open read-write

  for my $name ($c->readwrite ())
    {
      my $d = $self->repo ($name);
      $self->warning ("readwrite $name: $name is not a directory (dir) of the workspace")
        unless ($d && $d->isa ('vimgit::dir'));
    }
}

sub discover
{

# write .vimgit/config in $dir, listing the git repositories found in its entries
# (symbolic links followed; aliases and sub-directories of a repository skipped);
# returns the number of repositories

  my ($class, $dir) = @_;

  my (@mount, %seen);

  opendir (my $dh, $dir) or die ("Cannot read $dir");

  my @e = sort grep { (! m/^\./o) && (-d "$dir/$_") } readdir ($dh);

  closedir ($dh);

# real directories first, so that a repository is not listed under the name of a link to it

  for my $e ((grep { ! -l "$dir/$_" } @e), (grep { -l "$dir/$_" } @e))
    {
      my $d = "$dir/$e";
      my $top = 'vimgit::git'->getTopDirectory (dir => $d) or next;
      next unless (&Cwd::abs_path ($d) eq &Cwd::abs_path ($top));
      next if ($seen{&Cwd::abs_path ($top)}++);
      push @mount, $e;
    }

  @mount = sort @mount;

  return 0 unless (@mount);

  &mkpath ("$dir/.vimgit");

  my $fh = 'FileHandle'->new (">$dir/.vimgit/config") or die ("Cannot write $dir/.vimgit/config");

  $fh->print (<< 'EOF');
# vimgit workspace, written by vimgit; edit it. It is Perl, read after
# ~/.vimgit/config, whose settings it can add to or override.
#
# repo qw (<path> ...);              git repositories to search; results follow
#                                    their order; repositories not listed are ignored
# exclude <repo> => '<pattern>';     files of <repo> not to index (gitignore pattern,
#                                    relative to the top of <repo>), e.g.
#                                    exclude fiat => 'tests/**'; '-<pattern>' removes
#                                    a pattern from ~/.vimgit/config
# index qw (<glob> ...);             names of the files to index, any case, instead of
#                                    *.f90 *.f *.c *.cc *.cpp *.h *.hpp
# blacklist qw (<name> ...);         routines left out of call trees (:CT, :CTR), any
#                                    case, * for any characters, e.g. MPL_*;
#                                    '-<name>' removes a name, '-' all of them
# git, vim, jobs, results, gitgrep, context, keep, depth, key : see README.md
#
# A .vimgitignore file (gitignore syntax) in any directory of a repository also
# excludes files. vimgit -c prints the settings in use and where they come from.

EOF
  $fh->print ("repo qw (" . join (' ', @mount) . ");\n");
  $fh->print ("\nblacklist 'DR_HOOK';\n") unless ('vimgit::config'->load ()->blacklist ());

  return scalar (@mount);
}

sub repos
{
  my $self = shift;
  return @{ $self->{repos} };
}

sub repo
{

# repository by mount

  my ($self, $mount) = @_;
  my ($repo) = grep { $_->{mount} eq $mount } $self->repos ();
  return $repo;
}

sub repo_of
{

# repository holding workspace path $f, and the path of $f in it; () if none

  my ($self, $f) = @_;

  $f = 'File::Spec'->canonpath ($f);

# longest mount first

  for my $repo (sort { length ($b->{mount}) <=> length ($a->{mount}) } $self->repos ())
    {
      my $rel = $repo->relpath ($f);
      return ($repo, $rel) if (defined ($rel));
    }

  return ();
}

sub sets
{

# workspace paths grouped by repository : [ [ top, mount, [ repository paths ] ], ... ]

  my ($self, @f) = @_;

  my (%set, @set);

  for my $f (@f)
    {
      my ($repo, $rel) = $self->repo_of ($f) or next;
      unless ($set{$repo->{mount}})
        {
          push @set, ($set{$repo->{mount}} = [ $repo->{top}, $repo->{mount}, [] ]);
        }
      push @{ $set{$repo->{mount}}[2] }, $rel;
    }

  return \@set;
}

sub noindex
{

# repositories without an index, by mount; directories (dir) not writable are left out
# (they cannot have one, and are reported when the workspace is read)

  my $self = shift;
  return map { $_->{mount} } grep { ! defined ($_->indexhash ()) }
         grep { ! ($_->isa ('vimgit::dir') && ! -w $_->{top}) } $self->repos ();
}

sub lookup
{
  my ($self, $method, $arg, %args) = @_;

  my @repo = $self->repos ();

  @repo = grep { $_->{mount} eq $args{repo} } @repo
    if (defined ($args{repo}));

  return map { @{ $_->$method ($arg) || [] } } @repo;
}

sub files_for_word
{

# workspace paths of the files containing $word, repositories in config order;
# repo : search this repository only (mount)

  my ($self, $word, %args) = @_;
  return $self->lookup ('files_for_word', $word, %args);
}

sub paths_for_name
{

# workspace paths of the files named $name, repositories in config order

  my ($self, $name, %args) = @_;
  return $self->lookup ('paths_for_name', $name, %args);
}

# definitions and calls; a definition is { repo, key ("file:line", repository path), name,
# file (workspace path), line, internal (contained routine) }

sub refresh
{

# check the session caches of the repositories (HEAD moved, ...); returns the number of
# repositories whose index has definitions and calls (types : definitions of types)

  my ($self, %args) = @_;
  my $what = $args{types} ? 'types' : 'defs';
  return scalar (grep { my $c = $_->cache (); $c && $c->{$what} } $self->repos ());
}

sub blacklisted
{
  my ($self, $name) = @_;
  return $self->{blacklist} && ($name =~ $self->{blacklist});
}

sub definition_
{
  my ($self, $repo, $key, $name) = @_;
  my ($rel, $line, $internal) = ($key =~ m/^(.*):(\d+)(\*?)$/o);
  return { repo => $repo, key => "$rel:$line", name => $name, file => $repo->path ($rel), line => $line,
           internal => ($internal ? 1 : 0) };
}

sub definitions
{

# definitions of routine $name in the indexed repositories (after refresh), the most likely
# first : in the file of $args{caller}, in its repository, in a file named after the routine,
# in the first repository of the config; routines contained in another file come last (they
# cannot be called from there); types : definitions of type $name, same order, $args{caller}
# being the type using it

  my ($self, $name, %args) = @_;

  $name = lc ($name);

  my @repo = $self->repos ();
  my %rank = map { ($repo[$_]{mount}, $_) } (0 .. $#repo);

  my $method = $args{types} ? 'types' : 'definitions';
  my @d = map { my $repo = $_; map { $self->definition_ ($repo, $_, $name) } @{ $repo->$method ($name) } } @repo;

  my $caller = $args{caller};

  my $score = sub
  {
    my $d = shift;
    (my $base = lc (&basename ($d->{file}))) =~ s/\..*//o;
    my $samefile = $caller && ($d->{file} eq $caller->{file});
    return ($samefile ? 0 : 1,
            (($d->{internal} && ! $samefile) ? 1 : 0),
            ($caller && ($d->{repo} == $caller->{repo})) ? 0 : 1,
            ($base eq $name) ? 0 : 1,
            $rank{$d->{repo}{mount}});
  };

  my %s = map { ($_, [ $score->($d[$_]) ]) } (0 .. $#d);

  my @i = sort { my ($x, $y) = ($s{$a}, $s{$b});
                 ($x->[0] <=> $y->[0]) || ($x->[1] <=> $y->[1]) || ($x->[2] <=> $y->[2])
              || ($x->[3] <=> $y->[3]) || ($x->[4] <=> $y->[4]) || ($a <=> $b) } (0 .. $#d);

  return @d[@i];
}

sub callees
{

# names of the routines called by definition $d

  my ($self, $d) = @_;
  return @{ $d->{repo}->callees ($d->{key}) };
}

sub callers
{

# definitions calling routine $name, repositories in config order

  my ($self, $name) = @_;

  $name = lc ($name);

  return map { my $repo = $_; map { $self->definition_ ($repo, $_, $repo->nameof ($_)) } @{ $repo->callers ($name) } } $self->repos ();
}

sub components
{

# components of derived types of type definition $d : [ { kind (type, class, extends), type,
# name, line, file } ], the parent type first

  my ($self, $d) = @_;
  return map { { %$_, file => $d->{file} } } @{ $d->{repo}->components ($d->{key}) };
}

sub users
{

# types using type $name : [ { def (definition of the type using it), component (undef for
# an extension) } ], repositories in config order

  my ($self, $name) = @_;

  $name = lc ($name);

  return map { my $repo = $_;
               map { { def => $self->definition_ ($repo, $_->[0], $repo->typenameof ($_->[0])), component => $_->[1] } }
               @{ $repo->users ($name) } } $self->repos ();
}

1;
