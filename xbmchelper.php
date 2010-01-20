#!/usr/bin/env php
<?php

function getDirectories($dir) {
	$handle = opendir($dir);
	$subDirs = array();
	while($files = readdir($handle)) {
		if (!is_dir($files) || ($files == '.') || ($files == '..')) {
			continue;
		}
		$subDirs[] = $files;
	}
    closedir($handle);
    sort($subDirs);
    return $subDirs;
}

function hasThumbnail($dir) {
	$aviFiles = glob("$dir/*.avi");
	foreach ($aviFiles as $filename) {
	   echo "$filename\n";
	}
}

$movies = getDirectories('.');
//print_r($movies);

$missingFolderImages = array();
$missingFanartImages = array();
foreach ($movies as $movie) {
	if (!file_exists("$movie/folder.jpg")) {
		$missingFolderImages[] = $movie;
	}
    if (!file_exists("$movie/fanart.jpg")) {
        $missingFanartImages[] = $movie;
    }
    hasThumbnail($movie);
}

echo "Missing folder.jpg:\n";
foreach ($missingFolderImages as $movie) {
	echo "  $movie\n";
}

echo "\nMissing fanart.jpg:\n";
foreach ($missingFanartImages as $movie) {
    echo "  $movie\n";
}

?>