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

sub runParallel
{

# run git commands, at most $max at a time; each command is [ $dir, @args ];
# returns their outputs, in the same order. Outputs go to temporary files, so that
# a command never waits for its output to be read.

  my ($class, %args) = @_;

  use File::Temp;
  use POSIX qw ();

  my @cmd = @{ $args{commands} };
  my $max = $args{max} || 16;

  my @tmp = map { 'File::Temp'->new () } @cmd;
  my %running;

  for my $i (0 .. $#cmd)
    {
      if (keys (%running) >= $max)
        {
          my $pid = waitpid (-1, 0);
          delete $running{$pid};
        }

      my ($dir, @arg) = @{ $cmd[$i] };

      my $pid = fork ();
      defined ($pid) or die ("Cannot fork: $!");

      if ($pid == 0)
        {
# child : no cleanup of the parent (vim) must run here
          open (STDOUT, '>', $tmp[$i]->filename ());
          open (STDERR, '>', '/dev/null');
          { exec ($GIT, '--no-pager', -C => $dir, @arg) };
          &POSIX::_exit (127);
        }

      $running{$pid} = 1;
    }

  for my $pid (keys (%running))
    {
      waitpid ($pid, 0);
    }

  return map { local $/ = undef; my $fh = $_; seek ($fh, 0, 0); my $out = <$fh>; defined ($out) ? $out : '' } @tmp;
}

sub grepFiles
{

# search $args{word} (whole word, any case) with $args{context} lines around each match,
# in the files of $args{sets} : [ [ $top, $prefix, [ paths relative to $top ] ], ... ];
# git runs in $top (it skips paths crossing a symbolic link), several processes in parallel.
# Returns { "$prefix/$path" => [ [ line number, text ], ... ] } ($path alone if $prefix is '.');
# a line not following the previous one starts a new hunk.

  my ($class, %args) = @_;

  my $context = $args{context} || 0;

  my (@cmd, @prefix);

  for my $set (@{ $args{sets} })
    {
      my ($top, $prefix, $files) = @$set;
      for (my $i = 0; $i < @$files; $i += 500)
        {
          my $j = $i + 499; $j = $#$files if ($j > $#$files);
          push @cmd, [ $top, qw (grep --no-index -I -n -i -w --null), -C => $context,
                       -e => $args{word}, '--', @{$files}[$i .. $j] ];
          push @prefix, $prefix;
        }
    }

  my %hit;

  my @out = $class->runParallel (commands => \@cmd);

  for my $k (0 .. $#out)
    {
      for my $line (split (m/\n/o, $out[$k]))
        {
          next if ($line eq '--');
          my ($f, $n, $text) = split (m/\0/o, $line, 3);
          next unless (defined ($text));
          $f = "$prefix[$k]/$f" unless ($prefix[$k] eq '.');
          push @{ $hit{$f} }, [ $n, "$text\n" ];
        }
    }

  return \%hit;
}

sub grepRepository
{

# files of repository $args{top} (tracked, or untracked and not ignored) containing
# $args{word} (whole word, any case); paths relative to the top

  my ($class, %args) = @_;
  my @f = split (m/\0/o, &run ($args{top}, qw (grep --untracked -I -l -i -w -z), -e => $args{word}));
  return \@f;
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

sub getWorktreeGitDirectory
{

# absolute path of the git directory of this worktree (where HEAD is)

  my ($class, %args) = @_;
  chomp (my $dir = &run ($args{top}, qw (rev-parse --absolute-git-dir)));
  return $dir;
}

sub getFiles
{

# tracked files, plus untracked files not ignored; paths relative to the top

  my ($class, %args) = @_;
  my @f = split (m/\0/o, &run ($args{top}, qw (ls-files -z --cached --others --exclude-standard)));
  return \@f;
}

sub getExcluded
{

# files excluded by .vimgitignore files or by the gitignore patterns of $args{patterns} :
# among the files of $args{files} if given, otherwise among the tracked files and the files 
# of $args{untracked}; returns { path => 1 }. Both rule sets are applied separately, so that 
# a pattern excludes a file whatever a .vimgitignore says.

  my ($class, %args) = @_;

  my @rules = ([ '--exclude-per-directory=.vimgitignore' ]);
  push @rules, [ map { ('-x', $_) } @{ $args{patterns} } ]
    if (@{ $args{patterns} || [] });

  my @named = @{ $args{files} || $args{untracked} || [] };
  my @which = $args{files} ? qw (-c -o) : qw (-o);

  my %x;

  for my $rule (@rules)
    {
      $x{$_} = 1 for ($args{files} ? () : split (m/\0/o, &run ($args{top}, qw (ls-files -z -c -i), @$rule)));

# untracked files are named, so that git does not walk ignored directories

      for (my $i = 0; $i < @named; $i += 500)
        {
          my $j = $i + 499; $j = $#named if ($j > $#named);
          $x{$_} = 1 for (split (m/\0/o, &run ($args{top}, qw (ls-files -z -i), @which, @$rule,
                                               '--', @named[$i .. $j])));
        }
    }

  return \%x;
}

sub getUntracked
{

# untracked files not ignored; paths relative to the top

  my ($class, %args) = @_;
  my @f = split (m/\0/o, &run ($args{top}, qw (ls-files -z --others --exclude-standard)));
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
