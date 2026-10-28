package vimgit::dir;

# a directory of the workspace that is not a git repository (dir name => path in
# .vimgit/config); indexed like a repository, with what git provides done here :
# - the files : a walk of the directory, symbolic links not followed, .vimgit skipped,
#   exclude patterns and .vimgitignore files matched by vimgit::ignore;
# - the index : in <dir>/.vimgit/<digest>/, with a snapshot of the files (date and size);
# - the changes since the index : the snapshot compared with the walk, once per session.
# Its files are shown as <name>/<path>.

use strict;

use Cwd qw ();
use DB_File;
use Fcntl qw (O_RDONLY O_RDWR O_CREAT);
use File::Basename;
use File::Path;
use File::Spec;

use vimgit::git;
use vimgit::ignore;

use base qw (vimgit::repo);

sub new
{

# top : absolute path of the directory; mount : its name

  my ($class, %args) = @_;

  my $self = bless { %args }, $class;

  $self->{IDX} = "$self->{top}/.vimgit";

  return $self;
}

sub dir_
{

# directory of the index, for the current settings

  my $self = shift;
  return "$self->{IDX}/" . $self->digest ();
}

sub commits_
{

# a single "commit" : the directory as it is

  return [ 'dir' ];
}

sub head
{
  return 'dir';
}

sub relpath
{

# workspace path (<name>/<path>), or path of a file of the directory (absolute, or relative
# to the workspace) -> path relative to the directory; undef if not in the directory

  my ($self, $f) = @_;

  return $1 if ($f =~ m,^\Q$self->{mount}\E/(.*)$,);

  my $abs = 'File::Spec'->rel2abs ($f);
  my $d = &Cwd::abs_path (&dirname ($abs));
  return undef unless (defined ($d));
  $abs = "$d/" . &basename ($abs);

  return $abs =~ m,^\Q$self->{top}\E/(.*)$, ? $1 : undef;
}

sub realpath
{

# absolute path of file $rel (relative to the directory)

  my ($self, $rel) = @_;
  return "$self->{top}/$rel";
}

# exclusions : exclude patterns of the config, and .vimgitignore files, applied separately

sub rules_
{
  my $self = shift;

  unless ($self->{xrules})
    {
      $self->{xrules} = 'vimgit::ignore'->new ();
      $self->{xrules}->add ($_, '') for (@{ $self->{exclude} || [] });
      $self->{vrules} = 'vimgit::ignore'->new ();
      $self->{vread} = {};
    }

  return ($self->{xrules}, $self->{vrules});
}

sub vimgitignore_
{

# read the .vimgitignore of directory $d (relative to the top, '' for the top), and those of
# the directories above it, once

  my ($self, $d) = @_;

  my (undef, $v) = $self->rules_ ();

  my @c = grep { $_ ne '' } split (m,/,o, $d);
  for my $i (-1 .. $#c)
    {
      my $b = join ('/', @c[0 .. $i]);
      next if ($self->{vread}{$b}++);
      my $f = $b eq '' ? "$self->{top}/.vimgitignore" : "$self->{top}/$b/.vimgitignore";
      $v->addfile ($f, $b) if (-f $f);
    }
}

sub isexcluded_
{
  my ($self, $path, $isdir) = @_;
  my ($x, $v) = $self->rules_ ();
  my $d = &dirname ($path);
  $self->vimgitignore_ ($d eq '.' ? '' : $d);
  return $x->ignored ($path, $isdir) || $v->ignored ($path, $isdir);
}

sub excluded
{

# excluded files among $args{files}; without files, {} : the walk leaves them out

  my ($self, %args) = @_;
  return {} unless ($args{files});
  return { map { ($_, 1) } grep { $self->isexcluded_ ($_, 0) } @{ $args{files} } };
}

sub walk_
{

# the files of the directory, except excluded ones : { path => [ mtime, size ] }, once per
# session

  my $self = shift;

  return $self->{walk} if ($self->{walk});

  my %f;

  my $walk;
  $walk = sub
  {
    no warnings 'recursion';

    my $d = shift;
    my $abs = $d eq '' ? $self->{top} : "$self->{top}/$d";

    opendir (my $dh, $abs) or return;
    my @e = sort grep { ($_ ne '.') && ($_ ne '..') } readdir ($dh);
    closedir ($dh);

    $self->vimgitignore_ ($d);

    for my $e (@e)
      {
        my $p = $d eq '' ? $e : "$d/$e";
        my @st = lstat ("$abs/$e") or next;
        next if (-l _);
        if (-d _)
          {
            next if ($e eq '.vimgit');
            $walk->($p) unless ($self->isexcluded_ ($p, 1));
          }
        elsif (-f _)
          {
            $f{$p} = [ $st[9], $st[7] ] unless ($self->isexcluded_ ($p, 0));
          }
      }
  };

  $walk->('');

  return $self->{walk} = \%f;
}

sub files_
{
  my $self = shift;
  return [ sort keys (%{ $self->walk_ () }) ];
}

sub built_
{

# the snapshot of the files indexed in $dir : path -> "mtime size"

  my ($self, $dir, $files) = @_;
  my $w = $self->walk_ ();
  tie (my %F, 'DB_File', "$dir/files.db", O_RDWR | O_CREAT, 0666, $DB_HASH);
  $F{$_} = join (' ', @{ $w->{$_} }) for (@$files);
  untie (%F);
}

sub changes_
{

# files changed since the index : the snapshot against the walk

  my $self = shift;

  my %m;
  my $w = $self->walk_ ();

  tie (my %F, 'DB_File', $self->dir_ () . "/files.db", O_RDONLY) or return {};
  while (my ($f, $v) = each (%F))
    {
      if (! $w->{$f})
        {
          $m{$f} = '-';
        }
      elsif ($v ne join (' ', @{ $w->{$f} }))
        {
          $m{$f} = 'M';
        }
    }
  for my $f (keys (%$w))
    {
      $m{$f} = '+' unless (exists ($F{$f}));
    }
  untie (%F);

  return \%m;
}

sub ignored_
{
  return 0;
}

sub grep_
{

# files containing $word, without an index : git searches the files of the walk

  my ($self, $word) = @_;
  my $w = $self->walk_ ();
  my @f = split (m/\0/o, &vimgit::git::run ($self->{top}, qw (grep --no-index -I -l -i -w -z), -e => $word));
  return [ grep { $w->{$_} } @f ];
}

sub build
{

# the index; the directory must be writable

  my ($self, %args) = @_;
  die ("$self->{top} is not writable: no index for $self->{mount}\n") unless (-w $self->{top});
  return $self->SUPER::build (%args);
}

sub drop
{

# :R : directories are walked once per session, when first used
}

sub prune
{

# remove the indexes for other settings older than 30 days

  my $self = shift;

  my $digest = $self->digest ();

  opendir (my $dh, $self->{IDX}) or return;
  my @d = grep { m/^[0-9a-f]+$/o && ($_ ne $digest) && -d "$self->{IDX}/$_" } readdir ($dh);
  closedir ($dh);

  &rmtree ("$self->{IDX}/$_") for (grep { (stat ("$self->{IDX}/$_"))[9] < time () - 30 * 86400 } @d);
}

sub othersettings
{

# true if the directory has an index built with other settings

  my $self = shift;
  my $digest = $self->digest ();
  return scalar (grep { (&basename ($_) ne $digest) && (-f "$_/sindex.db") } glob ("$self->{IDX}/*"));
}

1;
