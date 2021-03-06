<?php
   /* This page uses partial form data from the calibration editor to build a
    * temporary tree definition based for this calibration, based on the currently
    * entered hints and taxa. These are marked to be INCLUDED (+) or EXCLUDED (-)
    * when searching for this calibration within the NCBI taxonomy.
    *
    * This is always an AJAX fetch from within the calibration editor page.
    * 
    * NOTE that this page does not go to great lengths to protect user input,
    * since the user is already a logged-in administrator.
    */
   require_once('../FCD-helpers.php');

   // open and load site variables
   require_once('../../config.php');

   $verbose = false;

if ($verbose) { ?>
<h3>POSTed data</h3>
<pre><?= print_r($_POST) ?></pre>
<? }

   // bail out now if there are no hints on either side of this node defintion
   if (!isset($_POST["hintName_A"]) && !isset($_POST["hintName_B"])) {
	?>
	<p style="color: #999; text-align: center;">
		No node-definition hints found! Include (or exclude) NCBI taxa above to help searchers find this calibration.
	</p>
	<? 
	return;
   } 

   // connect to mySQL server and select the Fossil Calibration database 
   // $connection=mysql_connect($SITEINFO['servername'],$SITEINFO['UserName'], $SITEINFO['password']) or die ('Unable to connect!');
   // NOTE that to use stored procedures and functions in MySQL, the newer mysqli API is recommended.
   ///mysql_select_db('FossilCalibration') or die ('Unable to select database!');
   $mysqli = new mysqli($SITEINFO['servername'],$SITEINFO['UserName'], $SITEINFO['password'], 'FossilCalibration');

   // build up a temporary table of node-definition hints for each side in turn
   $query="CREATE TEMPORARY TABLE preview_hints LIKE node_definitions";
   $result=mysqli_query($mysqli, $query) or die ('Error  in query: '.$query.'|'. mysqli_error($mysqli));

   $query="CREATE TEMPORARY TABLE preview_tree_definition (
		unique_name VARCHAR(80),
		entered_name VARCHAR(80),
		depth SMALLINT DEFAULT 0,
		source_tree VARCHAR(20),
		source_node_id INT(11),
		parent_node_id INT(11),
		is_pinned_node TINYINT(1) UNSIGNED,
		is_public_node TINYINT(1) UNSIGNED,
		calibration_id INT(11),
		is_explicit TINYINT UNSIGNED
	   ) ENGINE = memory";
   $result=mysqli_query($mysqli, $query) or die ('Error  in query: '.$query.'|'. mysqli_error($mysqli));

   $calibrationID = $_POST['CalibrationID'];

   foreach (Array('A', 'B') as $side) {
       // skip this side if no values were submitted
       if (isset($_POST["hintName_$side"])) {
	   $hintNames = $_POST["hintName_$side"];
	   $hintNodeIDs = $_POST["hintNodeID_$side"];
	   $hintNodeSources = $_POST["hintNodeSource_$side"];
	   $hintOperators = $_POST["hintOperator_$side"];
	   $hintDisplayOrders = $_POST["hintDisplayOrder_$side"];
   
	   // assemble values for each row, making all values safe for MySQL
	   $rowValues = Array();
	   $hintCount = count($hintNames);
	   for ($i = 0; $i < $hintCount; $i++) {
		   // check for vital node information before saving
		   if ((trim($hintNames[$i]) == "") || 
		       (trim($hintNodeSources[$i]) == "") || 
		       (trim($hintNodeIDs[$i]) == "")) { 
			   // SKIP this hint, it's incomplete
			   continue;
		   }
		   $rowValues[] = "('". 
			   $calibrationID ."','". 
			   $side ."','". 
			   mysqli_real_escape_string($mysqli, $hintNames[$i]) ."','". 
			   mysqli_real_escape_string($mysqli, $hintNodeSources[$i])."','". 
			   mysqli_real_escape_string($mysqli, $hintNodeIDs[$i]) ."','". 
			   mysqli_real_escape_string($mysqli, $hintOperators[$i]) ."','". 
			   mysqli_real_escape_string($mysqli, $hintDisplayOrders[$i]) ."')";
	   }
   
	   // make sure we have at least one valid row (hint) to save for this side
	   if (count($rowValues) > 0) {
		   $query="INSERT INTO preview_hints 
				   (calibration_id, definition_side, matching_name, source_tree, source_node_id, operator, display_order)
			   VALUES ". implode(",", $rowValues);
		   $result=mysqli_query($mysqli, $query) or die ('Error  in query: '.$query.'|'. mysqli_error($mysqli));
	   }
   
       }
   }
   $query='SELECT * FROM preview_hints';
   $result=mysqli_query($mysqli, $query) or die ('Error  in query: '.$query.'|'. mysqli_error($mysqli));
   $hints_data = array();
   while($row=mysqli_fetch_assoc($result)) {
      $hints_data[] = $row;
   }
   mysqli_free_result($result);


/*** TEST: let's copy this table to a permanent one 'TEST_preview_hints' ***
   $query="DROP TABLE IF EXISTS TEST_preview_hints";
   $result=mysqli_query($mysqli, $query) or die ('Error  in query: '.$query.'|'. mysqli_error($mysqli));

   $query="CREATE TABLE TEST_preview_hints LIKE preview_hints";
   $result=mysqli_query($mysqli, $query) or die ('Error  in query: '.$query.'|'. mysqli_error($mysqli));

   $query="INSERT TEST_preview_hints SELECT * FROM preview_hints";
   $result=mysqli_query($mysqli, $query) or die ('Error  in query: '.$query.'|'. mysqli_error($mysqli));
 *** END ***/


if ($verbose) { ?><h3><?= count($hints_data) ?> HINT(S) from preview_hints:</h3><?
   foreach( $hints_data as $row ) { ?>
<pre><?= print_r($row) ?></pre>
<? }
}

   ///$query='CALL getFullNodeInfo( "preview_hints", "preview_tree_definition" )';
   $query='CALL buildTreeDescriptionFromNodeDefinition( "preview_hints", "preview_tree_definition" )';
   $result=mysqli_query($mysqli, $query) or die ('Error in query: '.$query.'|'. mysqli_error($mysqli));
   while(mysqli_more_results($mysqli)) {
	/*?><?= mysqli_next_result($mysqli) ? '.' : '!' ?><?*/
	//mysqli_next_result($mysqli) or die ('Error in next result: '.$query.'|'. mysqli_error($mysqli)); // wait for this to finish
	mysqli_next_result($mysqli);
	mysqli_store_result($mysqli);
   }

   $query='SELECT * FROM preview_tree_definition';
   $result=mysqli_query($mysqli, $query) or die ('Error  in query: '.$query.'|'. mysqli_error($mysqli));
   $included_taxa_data = array();
   while($row=mysqli_fetch_assoc($result)) {
      $included_taxa_data[] = $row;
   }

if ($verbose) { ?><h3><?= count($included_taxa_data) ?> TAXA from preview_tree_definition:</h3><?
   foreach( $included_taxa_data as $row ) { ?>
<pre><?= print_r($row) ?></pre>
<? }
}

   mysqli_free_result($result);

   if (count($included_taxa_data) == 0) {
	   ?><p style="color: #999;">This calibration will not match a tip-taxa search on any NCBI taxa. Please include (+) more taxa above.</p><?
   } else {
	   ?><p style="color: #999;">This calibration will match tip-taxa searches within any of these <?= count($included_taxa_data) ?> NCBI taxa:</p><?
   }

   // "normalize" indentation to reflect the min and max depths in our list
   $minDepth = 999;
   $maxDepth = 0;
   foreach( $included_taxa_data as $row ) {
	$testDepth = $row['depth'];	
	$minDepth = min($testDepth, $minDepth);
	$maxDepth = max($testDepth, $maxDepth);
   }
   function treeDepthToIndent( $depth ) {
        global $minDepth;
	// convert a nominal depth to CSS indentation in px
	///return (($depth - $minDepth) * 20).'px';
	return ($depth * 15).'px';
   }
 
   foreach( $included_taxa_data as $row ) {

/* already reported above
       if ($verbose) { ?><h3>INCLUDED TAXON</h3>
	<pre><?= print_r($row) ?></pre>
      <? }
*/

      ?><i style="padding-left: <?= treeDepthToIndent($row['depth']) ?>;"><?= $row['unique_name'] ?></i><?
      if ($row['entered_name'] && ($row['entered_name'] != $row['unique_name'])) { 
          ?>&nbsp; (entered as '<?= $row['entered_name'] ?>')<?
      }
      ?><br/><?
   }


/*** TEMPORARY test of custom-tree-generation logic   
   $query='CALL updateTreeFromDefinition( '.$calibrationID.', "preview_tree_definition" )';
   $result=mysqli_query($mysqli, $query) or die ('Error in query: '.$query.'|'. mysqli_error($mysqli));
   while(mysqli_more_results($mysqli)) {
	//mysqli_next_result($mysqli) or die ('Error in next result: '.$query.'|'. mysqli_error($mysqli)); // wait for this to finish
	mysqli_next_result($mysqli);
	mysqli_store_result($mysqli);
   }
?><p><i style="color: #999;">Custom tree regen completed &mdash; <?= time() ?></i></p><?
 ***/

?>
