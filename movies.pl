#!/usr/bin/perl -w

use strict;
use File::Basename;
use File::Find;
use Getopt::Long;
use IMDB::Film;
use File::Listing qw(parse_dir);
use HTML::Table;
use Data::Dumper;

my $SCRIPTNAME = basename ($0);

my $USAGE = <<USAGE_END;
Usage: $SCRIPTNAME [options] PATH

USAGE_END

my $PAGE_HDR = <<PAGE_HDR_END;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN">
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <title>Movie Ratings</title>
    <link rel="stylesheet" type="text/css" href="main.css"/>
  </head>
  <body>
PAGE_HDR_END

my %movie_names;
my %rated_movies;
my @tdirs = qw(/home/nelson/torrents/movies
               /media/disk/torrents/movies_watched);
my @problems;
my $debug;
my ($name, $type, $size, $mtime, $mode);
my $table;
my $unrated = -1;

sub getImdbInfo {
    my $name = shift;
    my ($key, $sub, $rating, $vnum) = (0, '', 0, 0);
    my ($titleLower, $nameLower);

    if (exists($movie_names{$name}{'imdb'})) {
        $key = $movie_names{$name}{'imdb'};
    }
    else {
        $key = $name;
    }

    my $imdbObj = new IMDB::Film(crit => $key, debug => 0, cache => 1);

    if (!$imdbObj->status) {
        print "Something wrong for $name: ".$imdbObj->error . "\n";
        push(@problems, $name);
        return;
    }

    my $href = "<a href=\"http://www.imdb.com/title/tt" . $imdbObj->code()
        . "/\">" . $imdbObj->title() . "</a>";
    ($titleLower = $imdbObj->title()) =~ tr/A-Z/a-z/;
    ($nameLower = $name) =~ tr/A-Z/a-z/;
    if (($titleLower ne $nameLower) && ($name !~ /^tt/)) {
        $href .= "<br/>" . $name;
    }

    if (exists($movie_names{$name}{'sub'})) {
        $sub .= "sub ";
    }

    if (exists($movie_names{$name}{'srt'})) {
        $sub .= "srt ";
    }

    ($rating, $vnum) = $imdbObj->rating();

    if (!defined($rating)) {
        $key = $unrated;
        $unrated--;
        $rating = "n/a";
        $vnum = "n/a";
    }
    else {
        $key = $rating * $vnum * 10;
    }

    my $genres = join(" ", @{$imdbObj->genres()});
    if (exists($rated_movies{$key})) {
        $key .= " "; # just append a space to make it appear different
    }
    push(@{$rated_movies{$key}}, ($href, $sub, $genres, $imdbObj->year(),
                                  $rating, $vnum));
    print "href/". $href . " genres/" . $genres . " year/" . $imdbObj->year()
        . " rating/" . $rating . " votes/" . $vnum . "\n";
}

sub findNfoLink {
    my $fname = shift;
    my $result = '';

    my $matches = `grep -E "http:\/\/(us|uk|www)\.imdb\.com\/title\/" "$fname"`;
    #print "****" . $matches . "\n";
    if ($matches =~ /(tt\d+)/) {
        $result = $1;
    }
    return $result;
}

sub readDir {
    my $tdir = shift;
    my $nfolink;

    opendir(DIRHANDLE, $tdir) || die "Cannot opendir $tdir: $!";
    foreach my $name (sort readdir(DIRHANDLE)) {
	if ($name =~ /^\./) { next };
        if (-d "$tdir/$name") {
            ($movie_names{$name}{'name'} = $name) =~ s/\./ /g;
            $movie_names{$name}{'name'} =~ s/\[?DVD.+//ig;

            opendir(DIRHANDLE2, "$tdir/$name")
                || die "Cannot opendir $tdir: $!";
            foreach my $name2 (sort readdir(DIRHANDLE2)) {
                if ($name2 =~ /\.nfo$/) {
                    my $nfolink = findNfoLink("$tdir/$name/$name2");
                    if ($nfolink ne '') {
                        $movie_names{$name}{'imdb'} = $nfolink;
                    }
                }

                if (!exists($movie_names{$name}{'imdb'}) && ($name2 =~ /tt(\d+)\.txt/)) {
                    #print $name2 . " " . $1 . "\n";
                    $movie_names{$name}{'imdb'} = 'tt' . $1;
                }

                if ($name2 =~ /\.(sub|srt)$/) {
                    $movie_names{$name}{$1} = $name2;
                }
            }
        }
    }
}

sub makeTable {
    $table = new HTML::Table(-align =>'center', -border => 0);

    foreach $name (sort keys %movie_names) {
        print "... " . $name . " ...\n";
        getImdbInfo($name);
    }

    # sort in decending order
    my $row = 0;
    foreach my $rating (sort {$b <=> $a} keys %rated_movies) {
        $table->addRow(@{$rated_movies{$rating}});
        if (($row & 1) == 0) {
            $table->setRowBGColor($row, '#CCFFFF');
        }
        $row++;
    }

    return $table;
}

sub makeProblemsTable {
    $table = new HTML::Table(-align =>'center', -border => 0);

    if (scalar @problems > 0) {
        foreach (sort @problems) {
            $table->addRow($_);
        }
    }
    return $table;
}


if (!GetOptions ('debug' => \$debug)) {
    die "ERROR: bad options in command line\n";
}

if ($#ARGV >= 0) {
    @tdirs = ();
    foreach (@ARGV) {
        push(@tdirs, $_);
    }
}

foreach my $tdir (@tdirs) {
    my($filename, $directories, $suffix) = fileparse($tdir);

    # get name of file
    ($filename = $tdir) =~ s/\//\./g;
    $filename =~ s/^\.//g;

    print "Generating $filename.html...\n";

    %movie_names = ();
    %rated_movies = ();
    @problems = ();

    readDir($tdir);

    if (scalar keys %movie_names == 0) { die "movie names not found\n"; }

    $table = makeTable();

    open(HTML, "> $filename.html");

    print HTML $PAGE_HDR
        . "<h1>Movies in " . $tdir . "</h1>"
            . $table->getTable();

    if (scalar @problems > 0) {
        $table = makeProblemsTable();
        if ($table->getTableRows() > 0) {
            print HTML "<br/>Problems with following:\n";
            print HTML $table->getTable();
        }
    }

    print HTML "</body>\n</html>";

    close HTML;
}

0;
