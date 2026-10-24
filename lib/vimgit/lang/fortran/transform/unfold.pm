package vimgit::lang::fortran::transform::unfold;

use strict;
use base qw (vimgit::lang::fortran::transform::fold);
use Fxtran;

sub process
{
  my ($class, $node) = @_;
  &Fxtran::expand ($node);
  &vimgit::lang::fortran::transform::fold::normalizeCommas ($node);
}

1;
