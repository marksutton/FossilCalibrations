/*
 * Here's a family of stored procedures that probe the full multitree (the
 * super-set of all reference and user-defined trees). These calls can be
 * chained together to handle common use cases. Adapted from the NCBI-only
 * procedures defined previously.
 * 
 * NOTE that in all cases, we're using temporary tables to store our results.
 * This is the recommended alternative to CTEs in MySQL, and should support
 * easy implementation of the same behavior for different clients (the main FCD
 * website, a mobile version, non-web interfaces and APIs).
 */


/*
 * getFullNodeInfo( sourceTableName, destinationTableName )
 *
 * This takes a minimal table (eg, the result set from a multitree query):
 *   node_id
 *   parent_node_id
 *   is_public_path
 * and adds supplemental information about source nodes, node names, etc:
 *   multitree_node_id  -- NOTE that this will be duplicated for pinned nodes!
 *   source_tree
 *   source_node_id
 *   parent_node_id -- from source tree
 *   depth -- optional, if provided (specific to query target)
 *   name  -- TODO: different names based on source
 *   uniquename
 *   class -- refers to name type (eg, 'scientific name')
 *   node_status | is_public_node | is_public_path
 *   calibration_id    -- or NULL; only appears on root-node of FCD tree
 *   publication_desc  -- or NULL; incl. for all FCD nodes? short or full version?
 */

DROP PROCEDURE IF EXISTS getFullNodeInfo;

DELIMITER #

CREATE PROCEDURE getFullNodeInfo (IN sourceTableName VARCHAR(80), IN destinationTableName VARCHAR(80))
BEGIN

-- DECLARE any local vars here

DROP TEMPORARY TABLE IF EXISTS src;
DROP TEMPORARY TABLE IF EXISTS tmp;

-- we'll use prepared statements (dynamic SQL) to copy data between specified tables and "local" scratch tables
SET @sql = CONCAT('CREATE TEMPORARY TABLE src ENGINE=memory AS (SELECT * FROM ', sourceTableName ,');');
SELECT @sql as "";
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;

-- put resulting values into 'tmp' so we can rename+preserve them
CREATE TEMPORARY TABLE tmp AS 
SELECT DISTINCT
-- *
  src.node_id AS multitree_node_id
 ,src.parent_node_id AS parent_multitree_node_id
 ,src.depth AS query_depth
 -- ,src.is_public_path -- TODO: or node?
 ,COALESCE(identity.source_tree, 'NCBI') AS source_tree
 ,COALESCE(identity.source_node_id, src.node_id) AS source_node_id
 ,COALESCE(identity.is_pinned_node, 0) AS is_pinned_node
 -- ,COALESCE(FCDnames.name, NCBInames.name) AS name
 ,COALESCE(NULLIF(FCDnames.uniquename, ''), NULLIF(FCDnames.name, ''), NULLIF(NCBInames.uniquename, ''), NULLIF(NCBInames.name, ''), CONCAT(source_tree, ':', source_node_id)) AS uniquename
 ,COALESCE(NULLIF(FCDnames.class, ''), NCBInames.class) AS class
 ,FCDnodes.tree_id AS tree_id
 ,FCDtrees.calibration_id AS calibration_id  -- FCD_nodes.tree_id   FCD_trees.calibration_id   calibrations.NodePub   publications.PublicationID,ShortName
 ,IF(FCDtrees.root_node_id = FCDnodes.node_id, 1, 0) AS is_calibration_target
 ,pubs.ShortName AS publication_desc
 -- ,pubs.FullReference AS publication_full
FROM 
 src
LEFT OUTER JOIN node_identity AS identity ON (src.node_id = identity.multitree_node_id)
-- LEFT OUTER JOIN NCBI_nodes AS NCBInodes
--    ON (NCBInodes.taxonid = identity.multitree_node_id AND identity.source_tree = 'NCBI')
-- LEFT OUTER JOIN FCD_nodes AS FCDnodes
--    ON (FCDnodes.node_id = identity.multitree_node_id AND identity.source_tree != 'NCBI')
LEFT OUTER JOIN NCBI_names AS NCBInames ON (COALESCE(identity.source_tree, 'NCBI') = 'NCBI' AND COALESCE(identity.source_node_id, src.node_id) = NCBInames.taxonid AND NCBInames.class = 'scientific name')
LEFT OUTER JOIN FCD_names AS FCDnames ON (COALESCE(identity.source_tree, 'NCBI') != 'NCBI' AND COALESCE(identity.source_node_id, src.node_id) = FCDnames.node_id)
-- GROUP BY node_id
LEFT OUTER JOIN FCD_nodes AS FCDnodes ON identity.source_tree LIKE 'FCD-%' AND FCDnodes.node_id = identity.source_node_id
LEFT OUTER JOIN FCD_trees AS FCDtrees ON FCDtrees.tree_id = FCDnodes.tree_id
LEFT OUTER JOIN calibrations AS cals ON cals.CalibrationID = FCDtrees.calibration_id
LEFT OUTER JOIN publications AS pubs ON pubs.PublicationID = cals.NodePub
ORDER BY query_depth
;

-- PREPARE statement to create/replace named temp table, copy contents into it?
-- SET @sqlRenameTable = CONCAT('DROP TABLE IF EXISTS ', destinationTableName, '; ALTER TABLE tmp RENAME ', destinationTableName, ';');
SET @sql = CONCAT('DROP TABLE IF EXISTS ', destinationTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;
-- NOTE: just one statement allowed at a time! breaking this up...
SET @sql = CONCAT('ALTER TABLE tmp RENAME ', destinationTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;

DROP TEMPORARY TABLE IF EXISTS hier;
DROP TEMPORARY TABLE IF EXISTS tmp; -- just in case...

END #

DELIMITER ;



/*
 * getAllAncestors( p_multitree_node_id, destinationTableName, treeFilter )
 */

DROP PROCEDURE IF EXISTS getAllAncestors;

DELIMITER #

CREATE PROCEDURE getAllAncestors (IN p_multitree_node_id MEDIUMINT(8), IN destinationTableName VARCHAR(80), IN treeFilter VARCHAR(200))
BEGIN

-- Declarations must be at the very top of BEGIN/END block!
DECLARE v_done TINYINT UNSIGNED DEFAULT 0;
DECLARE v_depth SMALLINT DEFAULT 0;
DECLARE v_testNodeID MEDIUMINT(8) DEFAULT p_multitree_node_id;
DECLARE nodesFound INT DEFAULT 0;
DECLARE nodesFoundLastTime INT DEFAULT 0;

DROP TEMPORARY TABLE IF EXISTS hier;
DROP TEMPORARY TABLE IF EXISTS tmp;

-- let's try counting depth "backwards" from 0
CREATE TEMPORARY TABLE hier (
 node_id MEDIUMINT(8), 
 parent_node_id MEDIUMINT(8), 
 depth SMALLINT(6) DEFAULT 0
) ENGINE = memory;

INSERT INTO hier SELECT node_id, parent_node_id, v_depth FROM multitree WHERE node_id = p_multitree_node_id;

/* see http://dev.mysql.com/doc/refman/5.0/en/temporary-table-problems.html */

CREATE TEMPORARY TABLE tmp ENGINE=memory SELECT * FROM hier;

WHILE NOT v_done DO

    -- SELECT v_testNodeID AS "... LOOPING ... v_testNodeID", v_depth as "A. v_depth";

    TRUNCATE TABLE tmp;
    INSERT INTO tmp SELECT * FROM hier;

    -- SELECT * FROM hier; -- WHERE depth = v_depth;

    -- SELECT p.taxonid, p.parenttaxonid, v_depth FROM NCBI_nodes p 
      -- INNER JOIN tmp ON p.taxonid = tmp.parenttaxonid AND tmp.depth = v_depth;

    INSERT INTO hier 
	SELECT p.node_id, p.parent_node_id, (v_depth - 1) FROM multitree p 
	INNER JOIN tmp ON p.node_id = tmp.parent_node_id AND tmp.depth = v_depth AND tmp.node_id != p.node_id;
	-- final check is for "self-parenting" nodes like NCBI root

    -- SELECT * FROM hier; -- WHERE depth = v_depth;

    -- SELECT taxonid as "multiple IDs?" FROM hier WHERE depth = v_depth;

    -- when we stop finding new parent nodes, we're done
    SET nodesFound := (SELECT COUNT(*) FROM hier);

    -- SELECT nodesFound;
    -- SELECT nodesFoundLastTime;

    IF (nodesFound = nodesFoundLastTime) THEN
        SET v_done = 1;
    ELSE
        SET nodesFoundLastTime = nodesFound;
        SET v_depth:= v_depth - 1;          
    END IF;

    -- SET v_testNodeID = (SELECT node_id FROM hier WHERE depth = v_depth LIMIT 1);  
	-- TODO; find a more graceful allowance for multiple hits here
    -- IF v_testNodeID = 1 then   -- IS NULL THEN

    -- IF EXISTS(SELECT node_id FROM hier WHERE depth = v_depth AND node_id = 1) THEN
    --   SET v_done = 1;
    -- END IF;

END WHILE;

-- PREPARE statement to create/replace named temp table, copy contents into it?
SET @sql = CONCAT('DROP TABLE IF EXISTS ', destinationTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;
-- NOTE: just one statement allowed at a time! breaking this up...
SET @sql = CONCAT('ALTER TABLE hier RENAME ', destinationTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;

DROP TEMPORARY TABLE IF EXISTS hier; -- just in case...
DROP TEMPORARY TABLE IF EXISTS tmp;

END #

DELIMITER ;


/*
 * getMostRecentCommonAncestor( p_multitree_nodeA_id, p_multitree_nodeB_id, destinationTableName, treeFilter )
 */

DROP PROCEDURE IF EXISTS getMostRecentCommonAncestor;

DELIMITER #

CREATE PROCEDURE getMostRecentCommonAncestor (IN p_multitree_nodeA_id MEDIUMINT(8), IN p_multitree_nodeB_id MEDIUMINT(8), IN destinationTableName VARCHAR(80), IN treeFilter VARCHAR(200))
BEGIN

-- Declarations must be at the very top of BEGIN/END block!
DECLARE v_done TINYINT UNSIGNED DEFAULT 0;
DECLARE v_depth SMALLINT DEFAULT 0;
DECLARE v_testNodeID MEDIUMINT(8) DEFAULT p_multitree_nodeA_id;

-- clear "local" temp tables for the ancestor paths of each node
DROP TEMPORARY TABLE IF EXISTS tmp;
DROP TEMPORARY TABLE IF EXISTS tmp2;
DROP TEMPORARY TABLE IF EXISTS v_pathA;
DROP TEMPORARY TABLE IF EXISTS v_pathB;

-- gather both paths for analysis
CALL getAllAncestors( p_multitree_nodeA_id, "v_pathA", treeFilter );
			SELECT * FROM v_pathA;

CALL getAllAncestors( p_multitree_nodeB_id, "v_pathB", treeFilter );
			SELECT * FROM v_pathB;

-- walk the paths "backwards" in depth (from 0) to get the most recent common ancestor
-- use a simple, one-shot query if possible
-- NOTE: either path works as the source table, since we're looking for an
--  element in common and depth is always relative
CREATE TEMPORARY TABLE tmp AS
    SELECT * FROM v_pathA  as a
	WHERE a.node_id IN (SELECT node_id FROM v_pathB);

CREATE TEMPORARY TABLE tmp2 ENGINE=memory SELECT * FROM tmp;
/* see http://dev.mysql.com/doc/refman/5.0/en/temporary-table-problems.html */
DELETE FROM tmp WHERE depth < (SELECT MAX(depth) FROM tmp2);

-- PREPARE statement to create/replace named temp table, copy contents into it?
SET @sql = CONCAT('DROP TABLE IF EXISTS ', destinationTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;
-- NOTE: just one statement allowed at a time! breaking this up...
SET @sql = CONCAT('ALTER TABLE tmp RENAME ', destinationTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;

DROP TEMPORARY TABLE IF EXISTS tmp; -- just in case
DROP TEMPORARY TABLE IF EXISTS tmp2;

-- clear other "local" temp tables to avoid confusion
DROP TEMPORARY TABLE IF EXISTS v_pathA;
DROP TEMPORARY TABLE IF EXISTS v_pathB;

END #

DELIMITER ;


/*
 * getMultitreeNodeID( p_node_id, p_source_tree )
 *
 * Translates any node ID (reckoned from its source tree) to its corresponding
 * node ID in the current multitree.
 */

DROP FUNCTION IF EXISTS getMultitreeNodeID;

DELIMITER #

CREATE FUNCTION getMultitreeNodeID (p_source_tree VARCHAR(20), p_source_node_id MEDIUMINT(8) UNSIGNED)
RETURNS MEDIUMINT(8)
NOT DETERMINISTIC
BEGIN
  -- Declarations must be at the very top of BEGIN/END block!
  DECLARE response MEDIUMINT(8);

  SELECT multitree_node_id 
    FROM node_identity 
    WHERE source_tree = p_source_tree AND source_node_id = p_source_node_id
    INTO response;

  -- fall back to NCBI node ID for unpinned nodes
  RETURN IFNULL( response, p_source_node_id );
END #

DELIMITER ;


/*
 * getCladeFromNode( p_multitree_node_id, destinationTableName, treeFilter, limitDepth )
 *
 * NOTE that this requires a multitree ID for the target node!
 *
 * TODO: treeFilter is optional, expecting values like
 *  'ALL TREES'
 *  'ALL PUBLIC'
 *  '{tree-id}[,{another_tree_id} ...]'
 *
 * limitDepth returns n levels of descendants (eg, children only if 1), or all
 * descendants if NULL
 *
 */

DROP PROCEDURE IF EXISTS getCladeFromNode;

DELIMITER #

CREATE PROCEDURE getCladeFromNode (IN p_multitree_node_id MEDIUMINT(8), IN destinationTableName VARCHAR(80), IN treeFilter VARCHAR(200), IN limitDepth TINYINT UNSIGNED)
BEGIN

-- Declarations must be at the very top of BEGIN/END block!
DECLARE v_done TINYINT UNSIGNED DEFAULT 0;
DECLARE v_depth SMALLINT UNSIGNED DEFAULT 0;

DROP TEMPORARY TABLE IF EXISTS hier;
DROP TEMPORARY TABLE IF EXISTS tmp;

CREATE TEMPORARY TABLE hier (
 node_id MEDIUMINT(8), 
 parent_node_id MEDIUMINT(8), 
 depth SMALLINT(6) UNSIGNED DEFAULT 0
) ENGINE = memory;

INSERT INTO hier SELECT node_id, parent_node_id, v_depth FROM multitree WHERE node_id = p_multitree_node_id;

/* see http://dev.mysql.com/doc/refman/5.0/en/temporary-table-problems.html */

CREATE TEMPORARY TABLE tmp ENGINE=memory SELECT * FROM hier;

WHILE NOT v_done DO

-- SELECT '======== v_depth ========';
-- SELECT v_depth;
-- SELECT '======== hier ========';
-- SELECT * FROM hier;

    IF EXISTS( SELECT 1 FROM multitree p INNER JOIN hier ON p.parent_node_id = hier.node_id AND hier.depth = v_depth) THEN

        INSERT INTO hier 
            SELECT p.node_id, p.parent_node_id, v_depth + 1 FROM multitree p 
            INNER JOIN tmp ON p.parent_node_id = tmp.node_id AND tmp.depth = v_depth;

        SET v_depth = v_depth + 1;          

        TRUNCATE TABLE tmp;
        INSERT INTO tmp SELECT * FROM hier WHERE depth = v_depth;

        IF limitDepth IS NOT NULL THEN
            IF v_depth > limitDepth THEN
	        SET v_done = 1;
            END IF;
	END IF;

    ELSE
        SET v_done = 1;
    END IF;

    -- TODO: remove this!
    -- IF v_depth = 9 THEN SET v_done := 1; END IF;

END WHILE;
 
-- 
-- SELECT v_depth;
-- SELECT '======== tmp ========';
-- SELECT * FROM tmp;
-- SELECT '======== hier ========';
-- SELECT * FROM hier;
-- 

-- put resulting values into 'tmp' so we can rename+preserve them
INSERT INTO tmp SELECT DISTINCT
 p.node_id,
 b.node_id AS parent_node_id,
 hier.depth
FROM 
 hier
INNER JOIN multitree p ON hier.node_id = p.node_id
LEFT OUTER JOIN multitree b ON hier.parent_node_id = b.node_id
ORDER BY
 hier.depth, hier.node_id;

-- PREPARE statement to create/replace named temp table, copy contents into it?
-- SET @sqlRenameTable = CONCAT('DROP TABLE IF EXISTS ', destinationTableName, '; ALTER TABLE tmp RENAME ', destinationTableName, ';');
SET @sql = CONCAT('DROP TABLE IF EXISTS ', destinationTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;
-- NOTE: just one statement allowed at a time! breaking this up...
SET @sql = CONCAT('ALTER TABLE tmp RENAME ', destinationTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;

DROP TEMPORARY TABLE IF EXISTS hier;
DROP TEMPORARY TABLE IF EXISTS tmp; -- just in case...

END #

DELIMITER ;



/*
 * buildTreeDescriptionFromNodeDefinition( hintTableName, treeDescriptionTableName )
 *
 * This takes a table of hints, using the schema for `node_definition`:
 *   calibration_id
 *   definition_side	-- A or B, as used in cladistic definitions
 *   matching_name	-- not used here?
 *   source_tree	-- source ('NCBI','FCD') for this hint's node
 *   source_node_id	-- for this hint's node
 *   operator		-- determines effect on the calculated tree
 *   display_order	-- not used here
 *
 * ... and builds a new "tree description" table, suitable for either
 * 	* building a "preview" of the resulting table, or
 *	* generating and saving data to `FCD_nodes` and `node_identity`
 * This tree description table includes a row for each node in the new tree:
 *   unique_name	-- stored in new tree, displayed in preview
 *   entered_name  	-- include (in parentheses?) in preview
 *   depth		-- mainly used in preview
 *   source_tree	-- as above?
 *   source_node_id	-- as above?
 *   parent_node_id 	-- from source tree?
 *   is_pinned_node	-- or are all of them pinned?
 *   is_public_node	-- ?
 *   calibration_id     -- ?
 *   is_explicit	-- directly entered in hints, vs. implicitly calculated
 */

DROP PROCEDURE IF EXISTS buildTreeDescriptionFromNodeDefinition;

DELIMITER #

CREATE PROCEDURE buildTreeDescriptionFromNodeDefinition (IN hintTableName VARCHAR(80), IN treeDescriptionTableName VARCHAR(80))
BEGIN

-- DECLARE any local vars here

DECLARE oldRecursionDepth INT;
DECLARE the_hint_source_tree VARCHAR(20);
DECLARE the_hint_node_id MEDIUMINT(8) UNSIGNED;
DECLARE the_hint_operator ENUM('+','-');
DECLARE MRCA_id MEDIUMINT(8) UNSIGNED;

-- a flag terminates the loop when no more records are found
DECLARE no_more_rows INT DEFAULT FALSE;

-- a cursor to fetch these fields
DECLARE hint_cursor CURSOR FOR SELECT source_tree, source_node_id, operator FROM hints ORDER BY NCBI_depth;

DECLARE CONTINUE HANDLER FOR NOT FOUND 
  SET no_more_rows = TRUE;

--
-- Let's try a simple, recursive approach to deal with quirky overrides of the NCBI tree.
--
SET oldRecursionDepth = @@SESSION.max_sp_recursion_depth;
SET @@SESSION.max_sp_recursion_depth = 255;  -- 255 is the maximum possible for MySQL

DROP TEMPORARY TABLE IF EXISTS hints;
DROP TEMPORARY TABLE IF EXISTS tdesc; 
DROP TEMPORARY TABLE IF EXISTS v_path;

-- Copy SIMPLIFIED hint data from specified soure to "local" scratch table. Here we
-- resolve any duplicate nodes to a single hint, INCLUDED (+) if *any* hint says so
-- (this resolves any "stem group" style definitions*, while maximizing discoverability)
-- 
-- NOTE that here we use MIN(operator) to prefer '+' vs. '-' where found. I suspect this 
-- is arbitrary, based on their order in the MySQL enum definition.
-- 
-- ?? BUT what about conflicing sides? eg, a stem-group definition with a taxon that
--    is INCLUDED (+) on side A but EXCLUDED (-) on side B?
--    Maybe that can be resolved by looking back to the original hints table.
SET @sql = CONCAT('CREATE TEMPORARY TABLE hints ENGINE=memory AS (
	SELECT 
		 calibration_id,
		 definition_side,
		 matching_name,
		 source_tree,
		 source_node_id,
		 MIN(operator) AS operator,
		 999 AS NCBI_depth
	FROM ', hintTableName ,'
	GROUP BY source_tree, source_node_id
);');
SELECT @sql as "";
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;


-- order hints by by taxon depth (distance from root of NCBI tree)
OPEN hint_cursor;

  the_loop: LOOP
    FETCH hint_cursor INTO the_hint_source_tree, the_hint_node_id, the_hint_operator;

    IF no_more_rows THEN 
      LEAVE the_loop;
    END IF;

    -- reckon its depth by counting ancestors, and save to scratch hints
    CALL getAllAncestors( the_hint_node_id, "v_path", the_hint_source_tree );
    -- SELECT * FROM v_path;
    UPDATE hints
      SET NCBI_depth = (SELECT COUNT(*) FROM v_path)
      WHERE source_tree = the_hint_source_tree AND source_node_id = the_hint_node_id;
  END LOOP;

CLOSE hint_cursor;


-- INSERT INTO hints VALUES (103, 'B', 'test name', 'NCBI', 999, '+', 3);
SELECT * FROM hints;


-- build the empty tree-description table

CREATE TEMPORARY TABLE tdesc (
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
) ENGINE = memory;

-- INSERT INTO tdesc VALUES ('test', 'test', 0, '',0,0,0,0,1,1); -- DEBUG
-- IF FALSE THEN -- DEBUG


-- reckon MRCA of all INCLUDED (+) taxa on *both* sides; add this first node to the tree description
SET no_more_rows = FALSE;
OPEN hint_cursor;

  -- this time nodes should be properly sorted by the depths assigned above
  FETCH hint_cursor INTO the_hint_source_tree, the_hint_node_id, the_hint_operator;
  -- ASSUMES that the deepest hint is from NCBI taxonomy
  SET MRCA_id  = the_hint_node_id;
  SELECT MRCA_id AS "starting MRCA_id";

  the_loop: LOOP
    FETCH hint_cursor INTO the_hint_source_tree, the_hint_node_id, the_hint_operator;

    IF no_more_rows THEN 
      LEAVE the_loop;
    END IF;

    IF the_hint_source_tree = 'NCBI' AND the_hint_operator = '+' THEN
	-- test against the current MRCA and keep going deeper...
	SELECT the_hint_node_id AS "testing MRCA against this node:";
        CALL getMostRecentCommonAncestor( MRCA_id, the_hint_node_id, "mostRecentCommonAncestor_ids", 'NCBI' );
	SET MRCA_id = (SELECT node_id FROM mostRecentCommonAncestor_ids);
	SELECT MRCA_id AS "deeper MRCA_id?";
    ELSE
	SELECT the_hint_node_id AS "skipping this hint...";
    END IF;
    
  END LOOP;

CLOSE hint_cursor;

CALL getFullNodeInfo( "mostRecentCommonAncestor_ids", "final_MRCA_info" );
SELECT * FROM final_MRCA_info;

-- add the deepest MRCA as the first entry in our tree definition
CALL addNodeToTreeDescription( 'NCBI', MRCA_id ); -- , hintTableName, treeDescriptionTableName )

-- IF there are no EXCLUDED (-) taxa, we're done! ELSE continue
IF (SELECT COUNT(*) FROM hints WHERE operator = '-') = 0 THEN
    SELECT "NO EXCLUDED STUFF, finishing early";
ELSE
    SELECT "FOUND SOME EXCLUDED STUFF, more work to do...";
    
    -- ?? Walk A and B sides separately? or all together? if separate, what happens
    -- ?? if they touch overlapping parts of the NCBI tree?

    -- walk the remaining ordered hints, from root to leaves, and for each taxon...
    SET no_more_rows = FALSE;
    OPEN hint_cursor;
    
      the_loop: LOOP
        FETCH hint_cursor INTO the_hint_source_tree, the_hint_node_id, the_hint_operator;
    
        IF no_more_rows THEN 
          LEAVE the_loop;
        END IF;

        -- IF it's INCLUDED (+)...
	IF the_hint_operator = '+' THEN
       
	    -- ? is this node already directly included in the tree description?
	    --   (eg, as a side effect of excluding another nearby)
            IF isExplicitlyIncludedInTreeDescription (the_hint_source_tree, the_hint_node_id) THEN
	        -- IF YES, ignore this hint and move to the next hint
                ITERATE the_loop;
            END IF;
       
	    -- ? is this node already within a clade in this tree description?
            CALL isImplicitlyIncludedInTreeDescription (the_hint_source_tree, the_hint_node_id, @isIncluded);
            IF @isIncluded THEN
	        -- IF YES, ignore this hint and move to the next hint
                ITERATE the_loop;
            END IF;
       
	    -- STILL HERE? explicitly include this node in the tree description
            CALL addNodeToTreeDescription (the_hint_source_tree, the_hint_node_id);
       
        -- ELSE it's EXCLUDED (-)...
        ELSE
       
            -- ? is this node currently within a clade in this tree description?
            CALL isImplicitlyIncludedInTreeDescription (the_hint_source_tree, the_hint_node_id, @isIncluded);
            IF NOT @isIncluded THEN
                -- IF NO, ignore this hint and move to the next hint
                ITERATE the_loop;
            END IF;
            
            -- STILL HERE? prune this node via a recursive walk toward the root node....
            CALL excludeNodeFromTreeDescription( the_hint_source_tree, the_hint_node_id );

        END IF;

      END LOOP;
    
    CLOSE hint_cursor;

    
END IF;

-- END IF; -- DEBUG

-- ?? *A/B resolution? recognition of stem-group definition for precise inclusion of the calibrated node?

-- PREPARE statement to create/replace named temp table, copy contents into it?
SET @sql = CONCAT('DROP TABLE IF EXISTS ', treeDescriptionTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;
-- NOTE: just one statement allowed at a time! breaking this up...
SET @sql = CONCAT('ALTER TABLE tdesc RENAME ', treeDescriptionTableName, ';');
PREPARE cmd FROM @sql;
EXECUTE cmd;
DEALLOCATE PREPARE cmd;

-- clean up, just in case
DROP TEMPORARY TABLE IF EXISTS hints;
DROP TEMPORARY TABLE IF EXISTS tdesc;
DROP TEMPORARY TABLE IF EXISTS v_path;

-- reset recursion depth to default
SET @@SESSION.max_sp_recursion_depth = oldRecursionDepth;

END #

DELIMITER ;


/**********************************************************
 *
 *  Low-level helpers for the tree-definition procedures
 *
 **********************************************************/


/*
 * isExplicitlyIncludedInTreeDescription(hintNodeSource, hintNodeID)
 * 
 * ASSUMES we're using the temporary tables `hints` and `tdesc`
 */

/*
DROP PROCEDURE IF EXISTS isExplicitlyIncludedInTreeDescription;

DELIMITER #

CREATE PROCEDURE isExplicitlyIncludedInTreeDescription (IN hintNodeSource VARCHAR(20), IN hintNodeID MEDIUMINT(8), IN hintTableName VARCHAR(80), IN treeDescriptionTableName VARCHAR(80))
BEGIN

	...

END #

DELIMITER ;
*/
-- again, but as a simple function:
DROP FUNCTION IF EXISTS isExplicitlyIncludedInTreeDescription;

DELIMITER #

CREATE FUNCTION isExplicitlyIncludedInTreeDescription (hintNodeSource VARCHAR(20), hintNodeID MEDIUMINT(8))
RETURNS TINYINT(1)
NOT DETERMINISTIC
BEGIN
  -- Declarations must be at the very top of BEGIN/END block!
  DECLARE matchingNodesInDesc INT;

  SELECT COUNT(*)
    FROM tdesc 
    WHERE source_tree = hintNodeSource AND source_node_id = hintNodeID
    INTO matchingNodesInDesc;

  IF matchingNodesInDesc > 0 THEN
      RETURN TRUE;
  ELSE
      RETURN FALSE;
  END IF;
END #

DELIMITER ;


/*
 * isImplicitlyIncludedInTreeDescription( hintNodeSource, hintNodeID )
 * 
 * ASSUMES we're using the temporary tables `hints` and `tdesc`
 *
 * This would rather be a function, but not allowed as we're using dynamic SQL in the called procedures. :-/
 */

DROP PROCEDURE IF EXISTS isImplicitlyIncludedInTreeDescription;

DELIMITER #

CREATE PROCEDURE isImplicitlyIncludedInTreeDescription (IN hintNodeSource VARCHAR(20), IN hintNodeID MEDIUMINT(8), OUT result TINYINT)
BEGIN
  -- Declarations must be at the very top of BEGIN/END block!

  -- we'll loop through the tree-description table, checking identifiers
  DECLARE the_desc_source_tree VARCHAR(20);
  DECLARE the_desc_node_id MEDIUMINT(8) UNSIGNED;

  -- a flag terminates the loop when no more records are found
  DECLARE no_more_rows INT DEFAULT FALSE;

  -- a cursor to walk the tree description
  DECLARE def_cursor CURSOR FOR SELECT source_tree, source_node_id FROM tdesc;
  
  DECLARE CONTINUE HANDLER FOR NOT FOUND 
    SET no_more_rows = TRUE;

  SET result = FALSE;

  -- Test against the clade of all taxa currently in the tree-definition table
  -- Rather than fetching entire clades, let's just fetch the ancestors of the
  -- test node and compare them to the INCLUDEd nodes in the tree definition.
  CALL getAllAncestors( hintNodeID, "v_ancestors", 'NCBI' );

  -- SELECT * FROM v_ancestors;

  --   TODO: use a cursor for this..? and walk the nodes
  OPEN def_cursor;
  
    the_loop: LOOP
      FETCH def_cursor INTO the_desc_source_tree, the_desc_node_id;
  
      IF no_more_rows THEN 
        LEAVE the_loop;
      END IF;

      IF (the_desc_source_tree = hintNodeSource AND the_desc_node_id IN (SELECT node_id FROM v_ancestors)) THEN
          SET result = TRUE;
          LEAVE the_loop;
      END IF;
    END LOOP;
  
  CLOSE def_cursor;

END #

DELIMITER ;


/*
 * addNodeToTreeDescription( hintNodeSource, hintNodeID )
 * 
 * ASSUMES we're using the temporary tables `hints` and `tdesc`
 */

DROP PROCEDURE IF EXISTS addNodeToTreeDescription;

DELIMITER #

CREATE PROCEDURE addNodeToTreeDescription (IN hintNodeSource VARCHAR(20), IN hintNodeID MEDIUMINT(8))
BEGIN

-- EXAMPLE: addNodeToTreeDescription( 'NCBI', MRCA_id );
-- TODO: revisit all the values here... which are needed? where can we get all this information?
-- TODO: handle nodes that ARE or AREN'T in the hints table (incl. entered_name, etc)
-- TODO: use getFullNodeInfo to populate this?
-- TODO: carry depth somehow, so we can properly build a tree (and show nested preview)!

DROP TEMPORARY TABLE IF EXISTS v_node_ids;
-- fake this out with required properties..
CREATE TEMPORARY TABLE v_node_ids ENGINE=memory AS (SELECT 
	hintNodeID as node_id, 
	NULL as parent_node_id, 
	0 AS depth
);

CALL getFullNodeInfo( "v_node_ids", "v_node_info" );
-- SELECT * FROM v_node_info;

INSERT INTO tdesc (unique_name, entered_name, depth, source_tree, source_node_id, parent_node_id, is_pinned_node, is_public_node, calibration_id, is_explicit)
SELECT
	v_node_info.uniquename, -- unique_name = v_node_info.uniquename,
	hints.matching_name, -- entered_name = 'An entered name', -- TODO
	v_node_info.query_depth, -- depth = v_node_info.query_depth,  -- TODO
	hintNodeSource, -- source_tree = hintNodeSource,
	hintNodeID, -- source_node_id = hintNodeID,
	999, -- parent_node_id = 999,  -- TODO
	TRUE, -- is_pinned_node = TRUE,  -- TODO
	TRUE, -- is_public_node = TRUE,  -- TODO
	0, -- calibration_id = 0, -- TODO
	FALSE -- is_explicit = FALSE; -- TODO
FROM v_node_info
LEFT OUTER JOIN hints 
ON hints.source_node_id = hintNodeID;

END #

DELIMITER ;


/*
 * removeNodeFromTreeDescription( hintNodeSource, hintNodeID )
 *
 * This is straightforward removal of a row.
 * ASSUMES we're using the temporary tables `hints` and `tdesc`
 */

DROP PROCEDURE IF EXISTS removeNodeFromTreeDescription;

DELIMITER #

CREATE PROCEDURE removeNodeFromTreeDescription (IN hintNodeSource VARCHAR(20), IN hintNodeID MEDIUMINT(8))
BEGIN

  DELETE FROM tdesc WHERE source_tree = hintNodeSource AND source_node_id = hintNodeID;

END #

DELIMITER ;


/*
 * excludeNodeFromTreeDescription( hintNodeSource, hintNodeID )
 *
 * This is thorough exclusion of a node, incl. adding/removing others as needed.
 * ASSUMES we're using the temporary tables `hints` and `tdesc`
 */

DROP PROCEDURE IF EXISTS excludeNodeFromTreeDescription;

DELIMITER #

CREATE PROCEDURE excludeNodeFromTreeDescription (IN hintNodeSource VARCHAR(20), IN hintNodeID MEDIUMINT(8))
BEGIN

  DECLARE the_parent_node_id MEDIUMINT(8) UNSIGNED;
  DECLARE the_sibling_node_id MEDIUMINT(8) UNSIGNED;

  -- a flag terminates the loop when no more records are found
  DECLARE no_more_rows INT DEFAULT FALSE;

  -- a cursor to walk the tree description
  DECLARE sibling_cursor CURSOR FOR SELECT taxonid FROM NCBI_nodes WHERE parenttaxonid = the_parent_node_id;
  
  DECLARE CONTINUE HANDLER FOR NOT FOUND 
    SET no_more_rows = TRUE;

  -- prune this node via a recursive walk toward the root node....
  SELECT "PRUNING NOW...";

    -- is this node explicitly included? remove it and return
    IF isExplicitlyIncludedInTreeDescription (hintNodeSource, hintNodeID) THEN
        CALL removeNodeFromTreeDescription (hintNodeSource, hintNodeID);

    ELSE 
	-- it's implicitly included (in an included clade), so...
	-- remove this node (after fetching its parent-node's ID)

        -- SET the_parent_node_id := (SELECT MIN(parent_node_id) FROM tdesc WHERE source_tree = hintNodeSource AND source_node_id = hintNodeID);
        SET the_parent_node_id := (SELECT MIN(parenttaxonid) FROM NCBI_nodes WHERE taxonid = hintNodeID);

        CALL removeNodeFromTreeDescription (hintNodeSource, hintNodeID);

	-- add its siblings, IF they're not explicitly excluded in our hints
        OPEN sibling_cursor;
        
          the_loop: LOOP
            FETCH sibling_cursor INTO the_sibling_node_id;
        
            IF no_more_rows THEN 
              LEAVE the_loop;
            END IF;
		
            IF NOT the_sibling_node_id IN (SELECT source_node_id FROM hints WHERE source_tree = hintNodeSource AND operator = '-') THEN
              CALL addNodeToTreeDescription(hintNodeSource, the_sibling_node_id);
            END IF;

          END LOOP;
        
        CLOSE sibling_cursor;

        -- SELECT the_parent_node_id AS "testing parent node for possible recursion...";

        IF the_parent_node_id != hintNodeID THEN
	  -- we're not yet at the root; recurse to its parent node...
          CALL excludeNodeFromTreeDescription( hintNodeSource, the_parent_node_id );
        END IF;

    END IF;

END #

DELIMITER ;


/*
 * updateTreeFromDefinition (CalibrationID, treeDescriptionTableName)
 *
 * When a calibration is saved, this will build and add/replace its tree in the database.
 */

DROP PROCEDURE IF EXISTS updateTreeFromDefinition;

DELIMITER #

CREATE PROCEDURE updateTreeFromDefinition (IN calibrationID INT(11), IN treeDescriptionTableName VARCHAR(80))
BEGIN

	-- TODO

END #

DELIMITER ;



/*******************************************************************************
 *  Here's a typical query session, usable from the mysql command-line
 *
 *  NOTE that in all cases, we can create a temporary table by passing its
 *  (desired) name to a stored procedure. These can be disposed of explicitly,
 *  or they'll disappear when we close the database session.
 *******************************************************************************/

/***
-- normally we'd get these from user input, of course
SET @nodeA_id = 9606;	-- Homo sapiens
SET @nodeB_id = 349050;	-- Ficus casapiensis


-- SELECT will show variables, but requires a simple 'header' label or it looks dumb
SELECT CONCAT("=========================== MULTITREE ID for pinned NCBI node: ", @nodeA_id ," ===========================") AS "";

SET @multitreeID = getMultitreeNodeID( 'NCBI', @nodeA_id  );
SELECT @multitreeID;

SELECT CONCAT("=========================== MULTITREE ID for UN-pinned NCBI node: ", @nodeB_id ," ===========================") AS "";

SET @multitreeID = getMultitreeNodeID( 'NCBI', @nodeB_id  );
SELECT @multitreeID;


SELECT CONCAT("=========================== CLADE TEST for NCBI node: ", @nodeA_id ," ===========================") AS "";

SET @multitreeID = getMultitreeNodeID( 'NCBI', @nodeA_id  );

-- TODO: add tree_filter argument? eg, 'ALL_TREES', 'ALL_PUBLIC', or '{tree-id}[,{another_tree_id} ...]'
CALL getCladeFromNode( @multitreeID, "cladeA_ids", 'ALL_TREES', NULL );
SELECT * FROM cladeA_ids;

system echo "=========================== FULL INFO for clade members ==========================="

CALL getFullNodeInfo( "cladeA_ids", "cladeA_info" );
SELECT * FROM cladeA_info;



SELECT CONCAT("=========================== ALL ANCESTORS for node ID: ", @nodeA_id ," ===========================") AS "";

SET @multitreeID = getMultitreeNodeID( 'NCBI', @nodeA_id  );

CALL getAllAncestors( @multitreeID, "ancestorsA_ids", 'ALL TREES' );
SELECT * FROM ancestorsA_ids;

system echo "=========================== FULL INFO for all ancestors ==========================="

CALL getFullNodeInfo( "ancestorsA_ids", "ancestorsA_info" );
SELECT * FROM ancestorsA_info;



system echo "=========================== COMMON ANCESTOR ==========================="

SET @multitreeID_A = getMultitreeNodeID( 'NCBI', @nodeA_id  );
SET @multitreeID_B = getMultitreeNodeID( 'NCBI', @nodeB_id  );

CALL getMostRecentCommonAncestor( @multitreeID_A, @multitreeID_B, "mostRecentCommonAncestor_ids", 'ALL TREES' );
SELECT * FROM mostRecentCommonAncestor_ids;

system echo "=========================== FULL INFO for common ancestor ==========================="

CALL getFullNodeInfo( "mostRecentCommonAncestor_ids", "mostRecentCommonAncestor_info" );
SELECT * FROM mostRecentCommonAncestor_info;

***/



system echo "=========================== TREE DEFINITION ==========================="

SET @calibrationID = 104;
DROP TEMPORARY TABLE IF EXISTS testHints;
CREATE TEMPORARY TABLE testHints ENGINE=memory AS (SELECT * FROM node_definitions WHERE calibration_id = @calibrationID);

SELECT * FROM testHints;

CALL buildTreeDescriptionFromNodeDefinition( "testHints", "testTreeDef" );
SELECT * FROM testTreeDef;


system echo "=========================== DONE ==========================="


