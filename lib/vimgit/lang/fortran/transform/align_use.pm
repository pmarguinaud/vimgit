package vimgit::lang::fortran::transform::align_use;

use strict;
use base qw (vimgit::lang::fortran::transform);
use Fxtran;

use Data::Dumper;

sub apply
{
  my ($class, %args) = @_;
  
  my $edtr = $args{editor};
  my $buf = $edtr->getcurbuf ();
  my $win = $edtr->getcurwin ();

  my $dom = $class->xml_parse (editor => $edtr, buffer => $buf, file => $args{file});

  return unless ($dom);

  my ($row, $col) = $win->Cursor ();

  my @use = &F ('.//use-stmt', $dom);
  
  for my $use (@use)
    {
      my $count = 0;
      my @n = &F ('.//use-N/N/n', $use);
      for my $n (@n)
        {   
          my @expr = &F ('.//f:named-E[string(f:N)="?"]', $n->textContent, $dom);
          my @type = &F ('.//f:T-N[string(.)="?"]', $n->textContent, $dom);
          if (@expr || @type)
            {
              $count++;
              next;
            }
          my ($rename) = &F ('ancestor::rename', $n);
          $rename->unbindNode (); 
        }   
      $use->unbindNode unless ($count);
    }
  
  @use = &F ('.//use-stmt', $dom);
  
  my %use;
  
  for my $use (@use)
    {
      my ($N) = &F ('./module-N', $use, 1); 
      my @U = &F ('.//use-N/N/f:n', $use, 1); 
      for my $U (@U)
        {   
          $use{$N}{$U}++;
        }   
    }
  
  my ($len) = sort { $b <=> $a } map { length ($_) } keys (%use);
  
  for my $use (@use)
    {
      my ($N) = &F ('./module-N', $use, 1); 
      unless ($use{$N})
        {   
          $use->unbindNode;
          next;
        }   
      $use->replaceNode (&s (sprintf ("USE %-${len}s, ONLY : ", $N) . join (', ', sort keys (%{ $use{$N} }))));
    }

  my $n = $buf->Count ();
  $buf->Delete (1, $n);
  $buf->Append (0, split (m/\n/o, $dom->textContent));

  $win->Cursor ($row, $col);
}

1;
