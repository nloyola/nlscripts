#!/usr/bin/perl -w

use strict;
use LWP::Simple;
use Date::Manip;
use Data::Dumper;

# http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab
# http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab&date=2007-05-02

my %numbers;
my @past_dates = ();

my $num_table = 0;
my $date_options = 0;

my $lottoUrl = 'http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab';

my %our_numbers = (0 => [2, 7, 11, 25, 29, 48],
                   1 => [9, 33, 35, 36, 37, 46]);


my @valid_dates = ('2007-02-03', '2008-01-30');

sub parseLottoNumbers {
    my $url = shift;
    my $get_past_draws = shift;
    my $doc = get $url;
    my @numbers = ();

    for my $line (split("\n", $doc)) {
        if ($line =~ /header.*winning numbers/) {
            $num_table = 1;
        }
        elsif ($line =~ /See results from past dates/)
        {
            $num_table = 0;
            if ($get_past_draws) {
                $date_options = 1;
            }
        }
        elsif ($get_past_draws && ($line =~ /<\/form>/))
        {
            $date_options = 0;
        }
        elsif ($line eq "") {
            next;
        }

        if ($num_table) {
            if ($line =~ /<td><font class="faceonly" size="2">(\d{1,2})<\/font><\/td>/) {
                push (@numbers, $1);
            }

            if ($line =~ /<td bgcolor="#eeeeee" align="center"><font class="faceonly" size="2">(\d{1,2})<\/font><\/td>/) {
                push (@numbers, 'b' . $1);
            }
        }

        if ($get_past_draws && $date_options) {
            if ($line =~ /<option value="(\d{4})-(\d{2})-(\d{2})">/) {
                push (@past_dates, $1 . '-' . $2 . '-' . $3);
            }
        }
    }

    return @numbers;
}

parseLottoNumbers($lottoUrl, 1);

foreach my $date (@past_dates) {
    if (Date_Cmp($date, $valid_dates[0]) < 0) {
        last;
    }

    my $url = $lottoUrl . '&date=' . $date;
    print "Fetching numbers for " . $date . "...\n";
    @{ $numbers{$date} } = parseLottoNumbers($url, 0);
}

foreach my $date (sort keys %numbers) {
    if (scalar @{ $numbers{$date} } == 7) {
        if ($date eq '') {
            print "Last Draw: ";
        }
        else {
            print "Draw on " . $date . ": ";
        }

        foreach my $num (@{ $numbers{$date} }) {
            print $num . " ";
        }
        print "\n";
    }
}
