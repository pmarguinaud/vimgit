package vimgit::workspace;

# the directory vimgit works in, and its git repositories:
# - a directory holding .vimgit/config, which lists the repositories (repo <mount>),
#   in the order used for search results;
# - or the top of a git repository, alone (mounted at '.'), when there is no config

use strict;

use Cwd qw ();
use File::Basename;
use File::Path;
use File::Spec;
use FileHandle;

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

  if (-f "$self->{root}/.vimgit/config")
    {
      $self->readconfig ();
    }
  else
    {
      push @{ $self->{repos} }, 'vimgit::repo'->new (top => $self->{root}, mount => '.');
    }

  return $self;
}

sub warning
{
  my ($self, $msg) = @_;
  push @{ $self->{warnings} }, $msg;
}

sub readconfig
{
  my $self = shift;

  my $config = "$self->{root}/.vimgit/config";
  my $fh = 'FileHandle'->new ("<$config") or die ("Cannot read $config");

  my %seen; # top -> mount
  my (@exclude, @index);

  while (my $line = <$fh>)
    {
      $line =~ s/#.*//o;
      next unless ($line =~ m/\S/o);

      my ($key, @args) = split (' ', $line);

      if (($key eq 'repo') && (@args == 1))
        {
          my $mount = 'File::Spec'->canonpath ($args[0]);
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
      elsif (($key eq 'exclude') && (@args == 2))
        {
          push @exclude, [ @args ];
        }
      elsif (($key eq 'index') && (@args >= 1))
        {
          push @index, @args;
        }
      else
        {
          chomp ($line);
          $self->warning (".vimgit/config: cannot understand `$line'");
        }
    }

# exclude <repo> <pattern> : gitignore pattern, relative to the top of the repository

  for (@exclude)
    {
      my ($mount, $pattern) = @$_;
      if (my $repo = $self->repo ('File::Spec'->canonpath ($mount)))
        {
          push @{ $repo->{exclude} }, $pattern;
        }
      else
        {
          $self->warning (".vimgit/config: exclude $mount $pattern: $mount is not a repository of the workspace");
        }
    }

# index <glob> ... : names of the files to index, instead of the default list

  'vimgit::lang'->setindexed (@index) if (@index);

  $self->warning (".vimgit/config lists no repository") unless (@{ $self->{repos} });
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
# vimgit workspace, written by vimgit; edit it.
#
# repo <path>              a git repository to search; results follow the order
#                          of these lines; repositories not listed are ignored
# exclude <repo> <pattern> files of <repo> not to index (gitignore pattern,
#                          relative to the top of <repo>), e.g. exclude fiat tests/**
# index <glob> ...         names of the files to index, any case, instead of
#                          *.f90 *.f *.c *.cc *.cpp *.h *.hpp
#
# A .vimgitignore file (gitignore syntax) in any directory of a repository also
# excludes files. After changing exclusions or index, run vimgit -I.

EOF
  $fh->print ("repo $_\n") for (@mount);

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

sub noindex
{

# repositories without an index, by mount

  my $self = shift;
  return map { $_->{mount} } grep { ! defined ($_->indexhash ()) } $self->repos ();
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

1;
