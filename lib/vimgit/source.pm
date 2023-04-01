package vimgit::source;

use strict;

use Data::Dumper;
use File::Basename;

use base qw (vimgit::file);

sub new
{
  my $class = shift;
  my $self = bless { @_ }, $class;

  $self->{lang} ||= 'vimgit::lang'->lang ($self->{file});

  return $self;
}

sub do_edit
{

# edit a file; goto line passed as argument or previous location

  my ($self, %args) = @_;

  my $edtr = $args{editor};

  &VIM::DoCommand ("e $self->{file}");

  if ($args{line})
    {
      &VIM::DoCommand (":$args{line}");
      if ($args{column})
        {
          my $win = $edtr->getcurwin ();
          $win->Cursor ($args{line}, $args{column});
        }
    }
  else
    {
# last seen location
      &VIM::DoCommand (":silent normal '\"");
    }

}

sub path
{
  my ($self, $file) = @_;

  if (ref ($self) && (! $file))
    {
      $file = $self->{file};
    }

  for ($file)
    {
      s,^.*src=/,,o;
      s,^src/[^/]+/,,o;
    }

  return $file;
}

sub do_find
{

# make a search on word pointed to by cursor

  my ($self, %args) = @_;

  my $edtr = $args{editor};
  my $defn = $args{defn};
  my $call = $args{call};
  my $hist = $args{hist};

  my $curbuf = $edtr->getcurbuf ();
  my $curwin = $edtr->getcurwin ();

  my ($row, $col) = $curwin->Cursor ();
  
  my ($line) = $curbuf->Get ($row);

# find word pointed by cursor; this word is delimited by $i1 and $i2 in $line
  
  my ($word, $i1, $i2) = &vimgit::tools::findword ($col, $line);

  unless ($word)
    {
      &VIM::Msg (' ');
      return;
    }

  "vimgit::lang::$self->{lang}"->do_find (word => $word, i1 => $i1, i2 => $i2, line => $line, 
                                           editor => $edtr, defn => $defn, call => $call, 
                                           hist => $hist);

}

sub do_transform
{
  my ($self, %args) = @_;

  my $edtr = $args{editor};
  my ($transform, @args) = @{ $args{args} };

  my $lang = $self->{lang};

  my $class = "vimgit::lang::$lang\::transform::$transform";

  eval "use $class";

  $@ && die ($@);

  if ($class->can ('apply'))
    {
      $class->apply (editor => $edtr, file => $self, args => \@args);
    }
  else
    {
      &VIM::Msg ("`$transform' is not supported by $lang");
    }

}

1;
