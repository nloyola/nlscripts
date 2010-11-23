<?php

$unique_files = array();

if ($argc < 2) exit("directory not specified\n");

$dir = $argv[1];
$offset = empty($argv[2]) ? 1: intval($argv[2]);
$test = !empty($argv[3]);

$numbered_found = false;
$files = scandir($dir);
$filecount = count($files);
$sorted_files = array();

function check_unique($name) {
   global $test;
   global $unique_files;

   /*
   if ($test) {
      echo "check_unique: name/$name\n";
   }
   */

   if (!empty($unique_files[$name])) {
      exit("duplicate file found: $name\n");
   }

   $unique_files[$name] = 1;
}

foreach ($files as $file) {
   if (strpos($file, ".mp3") === false) continue;

   $matches = array();
   if (preg_match('/^(\d+)_(.*)$/', $file, $matches) === 1) {


      $match_offset = intval($matches[1]);
      if ($offset < $match_offset) {
         $offset = $match_offset;
         $numbered_found = true;
      }

      check_unique($matches[2]);

      echo "skipping $file\n";
      continue;
   }

   check_unique($file);

   $sorted_files[filemtime($file)] = array($file, date("F d Y H:i:s.", filemtime($file)));
}
ksort($sorted_files);
#print_r($sorted_files);

if ($numbered_found) {
   // numbered files already found
   ++$offset;
}

foreach ($sorted_files as $file) {
   $new_name = sprintf("%04d", $offset) . "_$file[0]";
   echo $file[0], ' -> ', $new_name, "\n";
   if (!$test) {
      rename($file[0], $new_name);
   }
   ++$offset;
}

?>