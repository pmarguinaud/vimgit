package vimgit::ignore;

# gitignore patterns matched without git, for directories that are not git repositories
# (vimgit::dir) : blank lines and # comments skipped, ! negates, a trailing / matches
# directories only, a / elsewhere anchors the pattern to its base directory, * and ? do not
# match /, ** matches any number of directories, [...] is a class. The last matching
# pattern wins; a file in an ignored directory is ignored.

use strict;

sub new
{
  my $class = shift;
  return bless { rules => [] }, $class;
}

sub glob2re_
{

# regular expression of glob $g (no leading or trailing /)

  my $g = shift;

  my $re = '';
  while (length ($g))
    {
      if ($g =~ s,^\*\*/,,o)
        {
          $re .= '(?:.*/)?';
        }
      elsif ($g =~ s,^/\*\*$,,o)
        {
          $re .= '/.*';
        }
      elsif ($g =~ s,^\*\*,,o)
        {
          $re .= '.*';
        }
      elsif ($g =~ s,^\*,,o)
        {
          $re .= '[^/]*';
        }
      elsif ($g =~ s,^\?,,o)
        {
          $re .= '[^/]';
        }
      elsif ($g =~ s,^\[(!|\^)?(\]?[^\]]*)\],,o)
        {
          my ($neg, $set) = ($1, $2);
          $set =~ s,([\\\[]),\\$1,go;
          $re .= '[' . ($neg ? '^' : '') . $set . ']';
        }
      elsif ($g =~ s,^\\(.),,o)
        {
          $re .= quotemeta ($1);
        }
      else
        {
          $g =~ s,^(.),,so;
          $re .= quotemeta ($1);
        }
    }

  return $re;
}

sub add
{

# add pattern $p, relative to directory $base ('' : the top)

  my ($self, $p, $base) = @_;

  $p =~ s/\r$//o;
  return if ($p =~ m/^\s*$/o);
  return if ($p =~ m/^#/o);
  $p =~ s/(?<!\\)\s+$//o;

  my $neg = ($p =~ s/^!//o) ? 1 : 0;
  $p =~ s/^\\([#!])/$1/o;

  my $dironly = ($p =~ s,/+$,,o) ? 1 : 0;
  return if ($p eq '');

# a / at the start or in the middle anchors the pattern to its base

  my $anchored = ($p =~ m,/,o) ? 1 : 0;
  $p =~ s,^/,,o;

  my $re = &glob2re_ ($p);
  $re = $anchored ? "^$re\$" : "^(?:.*/)?$re\$";

  push @{ $self->{rules} }, { re => qr/$re/s, neg => $neg, dironly => $dironly,
                              base => (defined ($base) ? $base : '') };
}

sub addfile
{

# add the patterns of file $file (a .vimgitignore), relative to directory $base

  my ($self, $file, $base) = @_;
  open (my $fh, '<', $file) or return;
  while (my $l = <$fh>)
    {
      chomp ($l);
      $self->add ($l, $base);
    }
  close ($fh);
}

sub match_
{

# 1 : ignored, 0 : not ignored (negated), undef : no pattern matches $path

  my ($self, $path, $isdir) = @_;

  my $r;
  for my $rule (@{ $self->{rules} })
    {
      next if ($rule->{dironly} && ! $isdir);
      my $p = $path;
      if ($rule->{base} ne '')
        {
          next unless ($p =~ s,^\Q$rule->{base}\E/,,);
        }
      $r = $rule->{neg} ? 0 : 1 if ($p =~ $rule->{re});
    }

  return $r;
}

sub ignored
{

# true if $path (relative to the top; isdir : a directory) is ignored, or is in an ignored
# directory

  my ($self, $path, $isdir) = @_;

  my @c = split (m,/,o, $path);
  for my $i (0 .. $#c - 1)
    {
      return 1 if ($self->match_ (join ('/', @c[0 .. $i]), 1));
    }

  return $self->match_ ($path, $isdir) ? 1 : 0;
}

1;
