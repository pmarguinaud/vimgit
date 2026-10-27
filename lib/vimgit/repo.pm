package vimgit::repo;

# one git repository of the workspace; its indexes and session cache hold paths
# relative to the top of the repository, turned into workspace paths (<mount>/<path>)
# only when returned

use strict;

use DB_File;
use Fcntl qw (O_RDONLY O_RDWR O_CREAT);
use File::Basename;
use File::Path;
use FileHandle;

use vimgit::git;
use vimgit::lang;
use vimgit::mini;

sub new
{

# top : absolute path of the top of the repository
# mount : path of the repository in the workspace ('.' when the workspace is the repository)

  my ($class, %args) = @_;

  my $self = bless { %args }, $class;

  $self->{gitdir} = 'vimgit::git'->getGitDirectory (top => $self->{top});
  $self->{IDX}    = "$self->{gitdir}/vimgit";

  return $self;
}

sub name
{
  my $self = shift;
  return $self->{mount};
}

sub path
{

# repository path -> workspace path

  my ($self, $f) = @_;
  return $self->{mount} eq '.' ? $f : "$self->{mount}/$f";
}

sub relpath
{

# workspace path -> repository path; undef if the file is not in this repository

  my ($self, $f) = @_;
  return $f if ($self->{mount} eq '.');
  return $f =~ m,^\Q$self->{mount}\E/(.*)$, ? $1 : undef;
}

sub excluded
{

# files excluded by .vimgitignore files and exclude lines of the config :
# among the files of $args{files}, or among all the files; returns { path => 1 }

  my ($self, %args) = @_;

  return 'vimgit::git'->getExcluded (top => $self->{top}, patterns => $self->{exclude},
                                     ($args{files} ? (files => $args{files})
                                                   : (untracked => 'vimgit::git'->getUntracked (top => $self->{top}))));
}

sub indexhash
{

# most recent of the last commits having an index; undef if none

  my $self = shift;

  my $hashlist = 'vimgit::git'->getHashList (top => $self->{top});

  for my $hash (@$hashlist)
    {
      return $hash if (-f "$self->{IDX}/$hash/sindex.db");
    }

  return undef;
}

sub uptodate
{

# true if the current commit has an index, with definitions, calls and types

  my $self = shift;
  my ($hash) = @{ 'vimgit::git'->getHashList (top => $self->{top}) };
  return $hash && ! grep { ! -f "$self->{IDX}/$hash/$_.db" } qw (windex sindex dindex cindex tindex tcindex);
}

sub build
{

# create the index of the current commit; force : even if it exists

  my ($self, %args) = @_;

  my $fhlog = $args{fhlog};

  my $hashlist = 'vimgit::git'->getHashList (top => $self->{top});
  die ("No commit in $self->{top}") unless (scalar (@$hashlist));

  my ($hash) = @$hashlist;

  my $dir = "$self->{IDX}/$hash";

  return if ((! $args{force}) && $self->uptodate ());

  &rmtree ($dir);
  &mkpath ($dir);

  my (%windex, %sindex, %dindex, %cindex, %tindex, %tcindex);

# files listed by git, relative to the top of the repository, except excluded files

  my $x = $self->excluded ();

  for my $f (grep { ! $x->{$_} } @{ 'vimgit::git'->getFiles (top => $self->{top}) })
    {
      &vimgit::wanted_windex_ (windex => \%windex, sindex => \%sindex, dindex => \%dindex, cindex => \%cindex,
                               tindex => \%tindex, tcindex => \%tcindex,
                               fhlog  => $fhlog, root => $self->{top}, file => $f);
    }

  for ([ dindex => \%dindex ], [ cindex => \%cindex ], [ tindex => \%tindex ], [ tcindex => \%tcindex ])
    {
      my ($name, $h) = @$_;
      tie (my %H, 'DB_File', "$dir/$name.db", O_RDWR | O_CREAT, 0666, $DB_HASH);
      &vimgit::cidx ($h, \%H);
      untie (%H);
    }

  tie (my %WINDEX,  'DB_File', "$dir/windex.db",  O_RDWR | O_CREAT, 0666, $DB_HASH);
  &vimgit::cidx (\%windex, \%WINDEX);
  untie (%WINDEX);

  tie (my %SINDEX,  'DB_File', "$dir/sindex.db",  O_RDWR | O_CREAT, 0666, $DB_HASH);
  &vimgit::cidx (\%sindex, \%SINDEX);
  untie (%SINDEX);

  $self->prune ();
}

sub prune
{

# keep the $keep most recent indexes

  my ($self, $keep) = @_;

  $keep ||= 3;

  opendir (my $dh, $self->{IDX}) or return;
  my @hash = grep { m/^[0-9a-f]{40}$/o && -d "$self->{IDX}/$_" } readdir ($dh);
  closedir ($dh);

  @hash = sort { (stat ("$self->{IDX}/$b"))[9] <=> (stat ("$self->{IDX}/$a"))[9] } @hash;

  &rmtree ("$self->{IDX}/$_") for (@hash[$keep .. $#hash]);
}

sub head
{

# commit of HEAD, read from the files of the git directory (no process);
# ask git when the layout is unusual

  my $self = shift;

  $self->{wtgitdir} ||= 'vimgit::git'->getWorktreeGitDirectory (top => $self->{top});

  my $slurp = sub { my $fh = 'FileHandle'->new ("<$_[0]") or return undef; local $/ = undef; my $t = <$fh>; $t };

  my $HEAD = $slurp->("$self->{wtgitdir}/HEAD");

  if (defined ($HEAD) && ($HEAD =~ m/^([0-9a-f]{40})\s*$/o))
    {
      return $1;
    }
  elsif (defined ($HEAD) && ($HEAD =~ m/^ref:\s*(\S+)\s*$/o))
    {
      my $ref = $1;

      my $sha = $slurp->("$self->{gitdir}/$ref");
      return $1 if (defined ($sha) && ($sha =~ m/^([0-9a-f]{40})\s*$/o));

      my $packed = $slurp->("$self->{gitdir}/packed-refs");
      return $1 if (defined ($packed) && ($packed =~ m/^([0-9a-f]{40}) \Q$ref\E$/m));
    }

  return 'vimgit::git'->getHead (top => $self->{top});
}

sub cache
{

# session cache : indexed commit, stored indexes, and files changed since that commit,
# scanned once; dropped when HEAD moves or on :R, updated when a file is written;
# undef if the repository has no index

  my $self = shift;

  my $head = $self->head ();

  delete $self->{cache}
    if ($self->{cache} && ($self->{cache}{head} ne $head));

  return $self->{cache} if ($self->{cache});

  my $hash = $self->indexhash ()
    or return undef;

  tie (my %WINDEX, 'DB_File', "$self->{IDX}/$hash/windex.db", O_RDONLY);
  tie (my %SINDEX, 'DB_File', "$self->{IDX}/$hash/sindex.db", O_RDONLY);

# definitions and calls : missing from indexes built before they existed

  my (%DINDEX, %CINDEX);
  my $defs = (-f "$self->{IDX}/$hash/dindex.db") && (-f "$self->{IDX}/$hash/cindex.db");

  if ($defs)
    {
      tie (%DINDEX, 'DB_File', "$self->{IDX}/$hash/dindex.db", O_RDONLY);
      tie (%CINDEX, 'DB_File', "$self->{IDX}/$hash/cindex.db", O_RDONLY);
    }

  my (%TINDEX, %TCINDEX);
  my $types = (-f "$self->{IDX}/$hash/tindex.db") && (-f "$self->{IDX}/$hash/tcindex.db");

  if ($types)
    {
      tie (%TINDEX, 'DB_File', "$self->{IDX}/$hash/tindex.db", O_RDONLY);
      tie (%TCINDEX, 'DB_File', "$self->{IDX}/$hash/tcindex.db", O_RDONLY);
    }

# windex : word -> { file }; sindex : basename -> { file };
# dindex : name -> { "file:line" }; cindex : "file:line" -> [ name ]; tindex, tcindex : the
# same for derived types and their components; findex : files whose stored entries are
# obsolete; wordsof : file -> words found in it; defsof : file -> names defined in it
# (routines and types)

  my $c = $self->{cache} = { head => $head, hash => $hash, defs => $defs, types => $types,
                             WINDEX => \%WINDEX, SINDEX => \%SINDEX, DINDEX => \%DINDEX, CINDEX => \%CINDEX,
                             TINDEX => \%TINDEX, TCINDEX => \%TCINDEX,
                             windex => {}, sindex => {}, dindex => {}, cindex => {}, tindex => {}, tcindex => {},
                             findex => {}, wordsof => {}, defsof => {} };

  my $m = 'vimgit::git'->getDiff (top => $self->{top}, hash => $hash);

# changed files : excluded ones are not scanned

  my $x = %$m ? $self->excluded (files => [ sort keys (%$m) ]) : {};

  for my $f (keys (%$m))
    {
      $c->{findex}{$f} = 1;
      $self->scan ($f) if ((($m->{$f} eq '+') || ($m->{$f} eq 'M')) && (! $x->{$f}));
    }

  return $c;
}

sub drop
{
  my $self = shift;
  delete $self->{cache};
  delete $self->{noindex};
}

sub noindex
{

# for a repository without an index : its files (tracked, or untracked and not ignored)
# except excluded files, listed once per session, again when HEAD moves

  my $self = shift;

  my $head = $self->head ();

  delete $self->{noindex}
    if ($self->{noindex} && ($self->{noindex}{head} ne $head));

  unless ($self->{noindex})
    {
      my $x = $self->excluded ();
      $self->{noindex} = { head => $head, excluded => $x,
                           files => [ grep { ! $x->{$_} } @{ 'vimgit::git'->getFiles (top => $self->{top}) } ] };
    }

  return $self->{noindex};
}

sub scan
{

# forget what is known about file $f (repository path), then scan it again

  my ($self, $f) = @_;

  my $c = $self->{cache};

  for my $w (@{ delete $c->{wordsof}{$f} || [] })
    {
      delete $c->{windex}{$w}{$f};
    }
  delete $c->{sindex}{&basename ($f)}{$f};

  for my $name (@{ delete $c->{defsof}{$f} || [] })
    {
      for my $t ([ 'dindex', 'cindex' ], [ 'tindex', 'tcindex' ])
        {
          my ($d, $k) = @$t;
          for my $key (grep { m/^\Q$f\E:\d+\*?$/ } keys (%{ $c->{$d}{$name} || {} }))
            {
              delete $c->{$d}{$name}{$key};
              (my $kk = $key) =~ s/\*$//o;
              delete $c->{$k}{$kk};
            }
        }
    }

  delete $c->{$_} for (qw (callers nameof users tnameof));

  $c->{findex}{$f} = 1;

  my (%w, %s, %d, %k, %t, %tc);
  &vimgit::wanted_windex_ (windex => \%w, sindex => \%s, dindex => \%d, cindex => \%k, tindex => \%t, tcindex => \%tc,
                           fhlog => $self->{fhlog}, root => $self->{top}, file => $f);

  for my $w (keys (%w))
    {
      $c->{windex}{$w}{$f} = 1;
      push @{ $c->{wordsof}{$f} }, $w;
    }
  for my $b (keys (%s))
    {
      $c->{sindex}{$b}{$f} = 1;
    }
  for my $name (keys (%d))
    {
      $c->{dindex}{$name}{$_} = 1 for (@{ $d{$name} });
      push @{ $c->{defsof}{$f} }, $name;
    }
  $c->{cindex}{$_} = $k{$_} for (keys (%k));
  for my $name (keys (%t))
    {
      $c->{tindex}{$name}{$_} = 1 for (@{ $t{$name} });
      push @{ $c->{defsof}{$f} }, $name;
    }
  $c->{tcindex}{$_} = $tc{$_} for (keys (%tc));
}

sub update
{

# file $f (repository path) was written; scan it again unless git ignores it,
# or it is excluded

  my ($self, $f) = @_;

  return unless ($self->{cache});
  return if ('vimgit::git'->isIgnored (top => $self->{top}, file => $f));
  return if ($self->excluded (files => [ $f ])->{$f});

  $self->scan ($f);
}

sub files_for_word
{

# workspace paths of the files containing $word, sorted; without an index, git searches
# the files

  my ($self, $word) = @_;

  my $c = $self->cache ();

  unless ($c)
    {
      my $n = $self->noindex ();
      my $ext = 'vimgit::lang'->indexed ();
      return [ map { $self->path ($_) } sort grep { (! $n->{excluded}{$_}) && ($_ =~ $ext) }
               @{ 'vimgit::git'->grepRepository (top => $self->{top}, word => $word) } ];
    }

  my %f = map { ($_, 1) }
          (keys (%{ $c->{windex}{$word} || {} }),
           grep ({ ! $c->{findex}{$_} } split (m/\s+/o, $c->{WINDEX}{$word} || '')));

  return [ map { $self->path ($_) } sort keys (%f) ];
}

sub paths_for_name
{

# workspace paths of the files named $name; without an index, from the list of files

  my ($self, $name) = @_;

  my $c = $self->cache ();

  unless ($c)
    {
      return [ map { $self->path ($_) } sort grep { &basename ($_) eq $name } @{ $self->noindex ()->{files} } ];
    }

  my %f = map { ($_, 1) }
          (keys (%{ $c->{sindex}{$name} || {} }),
           split (m/\s+/o, $c->{SINDEX}{$name} || ''));

  return [ map { $self->path ($_) } sort keys (%f) ];
}

# definitions and calls, from the session cache (refreshed by the caller); a definition is
# "file:line", file being a repository path; definitions of contained routines end with *

sub file_of_
{
  my $key = shift;
  return $key =~ m/^(.*):\d+\*?$/o ? $1 : $key;
}

sub defs_
{

# definitions of $name in table $t (dindex, tindex) : [ "file:line", ... ] ("file:line*" if
# contained), sorted

  my ($self, $t, $name) = @_;

  my $c = $self->{cache} or return [];
  my $T = uc ($t);

  my %d = map { ($_, 1) }
          (keys (%{ $c->{$t}{$name} || {} }),
           grep ({ ! $c->{findex}{&file_of_ ($_)} } split (m/\s+/o, $c->{$T}{$name} || '')));

  return [ sort keys (%d) ];
}

sub list_
{

# list of definition $key in table $t (cindex, tcindex)

  my ($self, $t, $key) = @_;

  my $c = $self->{cache} or return [];

  return $c->{$t}{$key} || [] if ($c->{findex}{&file_of_ ($key)});

  return [ split (m/\s+/o, $c->{uc ($t)}{$key} || '') ];
}

sub nameof_
{

# name of definition $key in table $t (dindex, tindex), from the reverse table $r, built at
# the first call

  my ($self, $t, $r, $key) = @_;

  my $c = $self->{cache} or return undef;

  unless ($c->{$r})
    {
      my %n;
      while (my ($name, $v) = each (%{ $c->{uc ($t)} }))
        {
          $n{s/\*$//or} = $name for (grep { ! $c->{findex}{&file_of_ ($_)} } split (m/\s+/o, $v));
        }
      while (my ($name, $v) = each (%{ $c->{$t} }))
        {
          $n{s/\*$//or} = $name for (keys (%$v));
        }
      $c->{$r} = \%n;
    }

  return $c->{$r}{$key};
}

sub definitions
{

# definitions of routine $name : [ "file:line", ... ] ("file:line*" if contained), sorted

  my ($self, $name) = @_;
  return $self->defs_ ('dindex', $name);
}

sub callees
{

# routines called by definition $key : [ name, ... ], in the order of the source

  my ($self, $key) = @_;
  return $self->list_ ('cindex', $key);
}

sub callers
{

# definitions calling routine $name : [ "file:line", ... ], sorted; the table of callers is
# built at the first call

  my ($self, $name) = @_;

  my $c = $self->{cache} or return [];

  unless ($c->{callers})
    {
      my %r;
      while (my ($key, $v) = each (%{ $c->{CINDEX} }))
        {
          next if ($c->{findex}{&file_of_ ($key)});
          $r{$_}{$key} = 1 for (split (m/\s+/o, $v));
        }
      while (my ($key, $v) = each (%{ $c->{cindex} }))
        {
          $r{$_}{$key} = 1 for (@$v);
        }
      $c->{callers} = \%r;
    }

  return [ sort keys (%{ $c->{callers}{$name} || {} }) ];
}

sub nameof
{

# name of the routine of definition $key

  my ($self, $key) = @_;
  return $self->nameof_ ('dindex', 'nameof', $key);
}

# derived types : definitions, components, types using a type, as for routines

sub types
{

# definitions of type $name : [ "file:line", ... ], sorted

  my ($self, $name) = @_;
  return $self->defs_ ('tindex', $name);
}

sub components
{

# components of type definition $key : [ { kind, type, name, line, attr }, ... ], the parent
# type first (kind extends), in the order of the source

  my ($self, $key) = @_;
  return [ map { my @f = split (m,/,o, $_, -1); { kind => $f[0], type => $f[1], name => $f[2], line => $f[3], attr => $f[4] } }
           @{ $self->list_ ('tcindex', $key) } ];
}

sub users
{

# types using type $name : [ [ "file:line", component ], ... ] for each component of type
# $name, [ "file:line", undef ] for each extension, sorted; the table is built at the first
# call

  my ($self, $name) = @_;

  my $c = $self->{cache} or return [];

  unless ($c->{users})
    {
      my %r;
      my $add = sub
      {
        my ($key, $tok) = @_;
        my ($kind, $type, $comp) = split (m,/,o, $tok, -1);
        $r{$type}{$key . "\t" . ($kind eq 'extends' ? '' : $comp)} = 1;
      };
      while (my ($key, $v) = each (%{ $c->{TCINDEX} }))
        {
          next if ($c->{findex}{&file_of_ ($key)});
          $add->($key, $_) for (split (m/\s+/o, $v));
        }
      while (my ($key, $v) = each (%{ $c->{tcindex} }))
        {
          $add->($key, $_) for (@$v);
        }
      $c->{users} = \%r;
    }

  return [ map { my ($key, $comp) = split (m/\t/o, $_, -1); [ $key, ($comp eq '' ? undef : $comp) ] }
           sort keys (%{ $c->{users}{$name} || {} }) ];
}

sub typenameof
{

# name of the type of definition $key

  my ($self, $key) = @_;
  return $self->nameof_ ('tindex', 'tnameof', $key);
}

1;
