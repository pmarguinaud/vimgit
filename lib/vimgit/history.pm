package vimgit::history;

use strict;
use Data::Dumper;

sub log : method
{
  my ($self, $fh) = @_;
  while (my ($win, $his) = each (%{ $self->{bywindow} }))
    {
      $fh->print ("$win\n");
      $fh->print (&Dumper ($his));
    }
}

sub new
{
  my $class = shift;
  my $self = bless { @_, bywindow => {} }, $class;
  return $self;
}

sub clear
{
  my ($self, $win) = @_;
  if ($win)
    {
      $self->{bywindow}{$win} = [];
    }
  else
    {
      $self->{bywindow} = {};
    }
}

sub push : method
{
  my ($self, $win, $method, %args) = @_;
  push @{ $self->{bywindow}{$win} }, [ $method, %args ];
}

sub pop : method
{
  my ($self, $win) = @_;
  return @{ pop (@{ $self->{bywindow}{$win} || [ ] } ) || [ ] };
}

1;
