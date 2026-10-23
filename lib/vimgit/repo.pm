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

# true if the current commit has an index

  my $self = shift;
  my ($hash) = @{ 'vimgit::git'->getHashList (top => $self->{top}) };
  return $hash && (-f "$self->{IDX}/$hash/windex.db") && (-f "$self->{IDX}/$hash/sindex.db");
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

  return if ((! $args{force}) && (-f "$dir/windex.db") && (-f "$dir/sindex.db"));

  &rmtree ($dir);
  &mkpath ($dir);

  my %windex;
  my %sindex;

# files listed by git, relative to the top of the repository, except excluded files

  my $x = $self->excluded ();

  for my $f (grep { ! $x->{$_} } @{ 'vimgit::git'->getFiles (top => $self->{top}) })
    {
      &vimgit::wanted_windex_ (windex => \%windex, sindex => \%sindex, fhlog  => $fhlog,
                               root => $self->{top}, file => $f);
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

# windex : word -> { file }; sindex : basename -> { file };
# findex : files whose stored entries are obsolete; wordsof : file -> words found in it

  my $c = $self->{cache} = { head => $head, hash => $hash, WINDEX => \%WINDEX, SINDEX => \%SINDEX,
                             windex => {}, sindex => {}, findex => {}, wordsof => {} };

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

  $c->{findex}{$f} = 1;

  my (%w, %s);
  &vimgit::wanted_windex_ (windex => \%w, sindex => \%s, fhlog => $self->{fhlog},
                           root => $self->{top}, file => $f);

  for my $w (keys (%w))
    {
      $c->{windex}{$w}{$f} = 1;
      push @{ $c->{wordsof}{$f} }, $w;
    }
  for my $b (keys (%s))
    {
      $c->{sindex}{$b}{$f} = 1;
    }
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

1;
