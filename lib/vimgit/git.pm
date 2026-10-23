package vimgit::git;

use strict;
use Data::Dumper;

my $GIT = '/bin/git';

sub run
{

# run a git command in repository $top; no shell involved

  my ($top, @cmd) = @_;

  open (my $fh, '-|', $GIT, '--no-pager', -C => $top, @cmd)
    or die ("Cannot run git: $!");
  local $/ = undef;
  my $out = <$fh>;
  close ($fh);

  return defined ($out) ? $out : '';
}

sub getHashList
{
  my ($class, %args) = @_;
  my @hash = split (m/\n/o, &run ($args{top}, qw (log --pretty=%H -10)));
  return \@hash;
}

sub getHead
{
  my ($class, %args) = @_;
  chomp (my $head = &run ($args{top}, qw (rev-parse HEAD)));
  return $head;
}

sub isIgnored
{

# true if git ignores $args{file} (a tracked file is never ignored)

  my ($class, %args) = @_;
  &run ($args{top}, qw (check-ignore -q), $args{file});
  return $? == 0;
}

sub getTopDirectory
{

# top of the repository containing $args{dir}; empty if not in a git repository

  my ($class, %args) = @_;

# git complains on stderr outside a repository
  open (my $err, '>&', \*STDERR);
  open (STDERR, '>', '/dev/null');
  my $ok = open (my $fh, '-|', $GIT, -C => $args{dir}, qw (rev-parse --show-toplevel));
  open (STDERR, '>&', $err);
  $ok or die ("Cannot run git: $!");

  chomp (my $top = <$fh> || '');
  close ($fh);
  return $? ? '' : $top;
}

sub getGitDirectory
{

# absolute path of the .git directory (shared by all worktrees)

  my ($class, %args) = @_;
  chomp (my $dir = &run ($args{top}, qw (rev-parse --path-format=absolute --git-common-dir)));
  return $dir;
}

sub getFiles
{

# tracked files, plus untracked files not ignored; paths relative to the top

  my ($class, %args) = @_;
  my @f = split (m/\0/o, &run ($args{top}, qw (ls-files -z --cached --others --exclude-standard)));
  return \@f;
}

sub getDiff
{

# files changed since commit $args{hash}, untracked files included; paths relative to the top

  my ($class, %args) = @_;

  my %m;

# no renames : a single path per entry; -z : status and path separated by NUL

  my @m = split (m/\0/o, &run ($args{top}, qw (diff --name-status --no-renames -z), $args{hash}));

  while (my ($m, $f) = splice (@m, 0, 2))
    {
      if ($m eq 'D')
        {
          $m{$f} = '-';
        }
      elsif ($m eq 'A')
        {
          $m{$f} = '+';
        }
      else
        {
# M, T (type change), U (unmerged), etc. : scan the working tree file
          $m{$f} = 'M';
        }
    }

  for (split (m/\0/o, &run ($args{top}, qw (ls-files -z --others --exclude-standard))))
    {
      $m{$_} = '+';
    }

  return \%m;
}

1;
