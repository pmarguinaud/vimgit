package vimgit::file;

use strict;
use Data::Dumper;

sub new
{
  my ($class, %args) = @_;

  my $self;

  if ('vimgit::file'->issource ($args{file}))
    {
      use vimgit::source;
      $self = 'vimgit::source'->new (%args);
    } 
  elsif ('vimgit::file'->issearch ($args{file}))
    {
      use vimgit::search;
      $self = 'vimgit::search'->new (%args);
    }
  else
    {
      $self = bless { @_ }, $class;
    }

  return $self;
}

sub issource
{

# check if file is a source code file

  my ($self, $file) = @_;

  if (ref ($self) && (! $file))
    {
      $file = $self->{file};
    }
  return ! ($file =~ m/search=/o);
}

sub issearch
{

# check if file is a search result

  my ($self, $file) = @_;

  if (ref ($self) && (! $file))
    {
      $file = $self->{file};
    }

  return $file =~ m/search=/o;
}

sub do_edit
{
}

sub do_find
{
}

1;
