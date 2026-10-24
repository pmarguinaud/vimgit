package vimgit::lang::fortran::transform::clean_associate;

use strict;
use base qw (vimgit::lang::fortran::transform);
use Fxtran;
use List::MoreUtils qw (uniq);
use List::Util qw (min max);

use Data::Dumper;

sub removeConstruct
{
# remove ASSOCIATE and END ASSOCIATE lines, keep the body of the construct

  my $assoc = shift;

  my ($stmt, $end) = ($assoc->firstChild, $assoc->lastChild);

# indentation of the ASSOCIATE line
  my $prev = $assoc->previousSibling;
  if ($prev && ($prev->nodeName eq '#text'))
    {
      (my $t = $prev->data) =~ s/[ \t]*$//o;
      $prev->setData ($t);
    }

# ASSOCIATE statement and the rest of its line
  $stmt->unbindNode ();
  while (my $c = $assoc->firstChild)
    {
      if (($c->nodeName eq '#text') && ($c->data =~ m/\n/o))
        {
          (my $t = $c->data) =~ s/^[^\n]*\n//o;
          $c->setData ($t);
          last;
        }
      $c->unbindNode ();
    }

# END ASSOCIATE statement and the beginning of its line
  $end->unbindNode ();
  while (my $c = $assoc->lastChild)
    {
      if (($c->nodeName eq '#text') && ($c->data =~ m/\n/o))
        {
          (my $t = $c->data) =~ s/\n[^\n]*$//o;
          $c->setData ($t);
          last;
        }
      $c->unbindNode ();
    }

  my $p = $assoc->parentNode;
  $p->insertBefore ($_, $assoc) for ($assoc->childNodes ());
  $assoc->unbindNode ();
}

sub apply
{
  my ($class, %args) = @_;
  
  my $edtr = $args{editor};
  my $buf = $edtr->getcurbuf ();
  my $win = $edtr->getcurwin ();

  my $dom = $class->xml_parse (editor => $edtr, buffer => $buf, file => $args{file});

  return unless ($dom);

  my ($row, $col) = $win->Cursor ();

  my @assoc = &F ('.//associate-construct', $dom);

# innermost constructs first : removing an inner construct may leave names of the outer one unused
  for my $assoc (reverse (@assoc))
    {
      my $stmt = $assoc->firstChild;
      &Fxtran::expand ($stmt);

# names used in the body of the construct (uppercase, without blanks)
      my %used = map { ($_, 1) } &F ('./*[position()>1]//named-E/N', $assoc, 1);

      my @N = &F ('./associate-LT/associate/associate-N', $stmt);

      my $empty = 0;
      for my $N (@N)
        {
          (my $n = uc ($N->textContent)) =~ s/\s+//go;
          next if ($used{$n});
          my $associate = $N->parentNode;
          $empty = &Fxtran::removeListElement ($associate);
        }

      if ($empty)
        {
          &removeConstruct ($assoc);
        }
      else
        {
          &Fxtran::fold ($stmt, align => 0);
        }
    }

  $class->buf_set_text (buffer => $buf, text => $dom->textContent);
  $win->Cursor ($row, $col);
}

1;
