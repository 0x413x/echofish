/* $Id$ */

SET FOREIGN_KEY_CHECKS=0;
SET SQL_MODE="NO_AUTO_VALUE_ON_ZERO";
SET time_zone = "+00:00";
SET NAMES utf8 COLLATE 'utf8_unicode_ci';


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8 */;

DELIMITER //

DROP PROCEDURE IF EXISTS delete_duplicate_whitelist//
CREATE PROCEDURE delete_duplicate_whitelist()
BEGIN
  DECLARE wid,wfacility,wlevel,done BIGINT DEFAULT 0;
  DECLARE whost,wprogram VARCHAR(255) DEFAULT '';
  DECLARE wpattern VARCHAR(512) DEFAULT '';
  DECLARE uwp CURSOR FOR SELECT id,host,program,facility,`level`,pattern FROM whitelist;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = -1;
  START TRANSACTION WITH CONSISTENT SNAPSHOT;
  OPEN uwp;

  read_loop: LOOP
      FETCH uwp INTO wid,whost,wprogram,wfacility,wlevel,wpattern;
      IF done = -1 THEN
        LEAVE read_loop;
      END IF;
    delete_segment: BEGIN
      DECLARE CONTINUE HANDLER FOR NOT FOUND SET @x='OUPS';
 	    DELETE FROM whitelist WHERE
          pattern LIKE wpattern AND
    		  program LIKE if(wprogram='' or wprogram is null,'%',wprogram) AND
      		facility like if(wfacility<0,'%',wfacility) AND
      		`level` like if(wlevel<0,'%',wlevel) AND
		      host LIKE if(whost='0','%',whost) AND
		      id!=wid;
 	  END delete_segment;
  END LOOP read_loop;
  CLOSE uwp;
  COMMIT;
END;
//

DROP PROCEDURE IF EXISTS extract_ipaddr//
CREATE PROCEDURE extract_ipaddr(IN msg VARCHAR(5000))
BEGIN
    DECLARE matching INT default 1;
    DECLARE ipaddr VARCHAR(255);
    SET ipaddr=(SELECT REGEXP_SUBSTR(msg, '\\d{1,3}(?:\.\\d{1,3}){3}'));
    tfer_loop:WHILE ( ipaddr IS NOT NULL and length(ipaddr)>0 ) DO
    SELECT ipaddr;
    SET matching=matching+1;
    SET msg=(SELECT REPLACE( msg, @ipaddr, '' ));
    SET ipaddr=(SELECT REGEXP_SUBSTR(msg, '?:\\d{1,3}(?:\.\\d{1,3}){3})'));
END WHILE tfer_loop;
END;
//


DROP PROCEDURE IF EXISTS archive_parser_trigger//
CREATE PROCEDURE archive_parser_trigger(IN aid BIGINT UNSIGNED,IN ahost BIGINT UNSIGNED,IN aprogram VARCHAR(255),IN afacility INT,in alevel INT,IN apid BIGINT,in amsg TEXT,in areceived_ts TIMESTAMP,IN ttype VARCHAR(10))
BEGIN
  DECLARE apid,done INT;
  DECLARE apptype,apname VARCHAR(255);
  DECLARE uwp CURSOR FOR SELECT id,name FROM archive_parser WHERE ptype=ttype ORDER BY weight,name,id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = -1;
  OPEN uwp;

  read_loop: LOOP
      FETCH uwp INTO apid,apname;
      IF done = -1 THEN
        LEAVE read_loop;
      END IF;

    SET @callquery=concat('CALL ',apname,'(?,?,?,?,?,?,?,?)');
    PREPARE stmtcall FROM @callquery;
    set @aid=aid;
    set @ahost=ahost;
    set @aprogram=aprogram;
    set @afacility=afacility;
    set @alevel=alevel;
    set @apid=apid;
    set @amsg=amsg;
    set @areceived_ts=areceived_ts;
    EXECUTE stmtcall USING @aid,@ahost,@aprogram,@afacility,@alevel,@apid,@amsg,@areceived_ts;
    DEALLOCATE PREPARE stmtcall;
  END LOOP read_loop;
  CLOSE uwp;
END;
//


DROP PROCEDURE IF EXISTS archive_parse_unparsed//
CREATE PROCEDURE archive_parse_unparsed()
BEGIN
DECLARE deadlock,done INT DEFAULT 0;
DECLARE attempts INT DEFAULT 0;
DECLARE auid BIGINT UNSIGNED DEFAULT 0;
DECLARE uwp CURSOR FOR SELECT id FROM archive_unparse WHERE pending=1 ORDER BY id LIMIT 10000;
DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = -1;
SET SESSION time_zone='+00:00';
START TRANSACTION;
OPEN uwp;
read_loop: LOOP
  FETCH uwp INTO auid;
  IF done = -1 THEN
    LEAVE read_loop;
  END IF;
  DELETE FROM archive_unparse WHERE id=auid;
  SELECT host,facility,`level`,program,pid,msg,received_ts INTO @ahost,@afacility,@alevel,@aprogram,@apid,@amsg,@areceived_ts FROM archive WHERE id=auid;
  IF @ahost IS NOT NULL AND @afacility IS NOT NULL AND @alevel IS NOT NULL AND @aprogram IS NOT NULL AND @apid IS NOT NULL AND @amsg IS NOT NULL THEN
    CALL archive_parser_trigger(auid,@ahost,@aprogram,@afacility,@alevel,@apid,@amsg,@areceived_ts,'archive');
    SET @hostexists=(SELECT count(*) FROM `host` WHERE id=@ahost);
    IF @hostexists IS NULL OR @hostexists = 0 and @ahost is not null THEN
	   INSERT INTO `host` (fqdn,short) values (@ahost,@ahost);
    END IF;
  END IF;
END LOOP read_loop;
CLOSE uwp;
COMMIT;
END;
//

/*
 * Simple wrapper around the insert for the log of abuser evidence
 */
DROP PROCEDURE IF EXISTS abuser_log_evidence//
CREATE PROCEDURE abuser_log_evidence(IN abuser_id BIGINT UNSIGNED,IN entry_id BIGINT UNSIGNED)
BEGIN
  INSERT INTO abuser_evidence (incident_id,archive_id) VALUES (abuser_id,entry_id);
END;
//

/*
 * Parse given entry through the abuser trigger rules.
 */
DROP PROCEDURE IF EXISTS abuser_parser//
CREATE PROCEDURE abuser_parser(IN aid BIGINT UNSIGNED,IN ahost BIGINT UNSIGNED,IN aprogram VARCHAR(255),IN afacility INT,in alevel INT,IN apid BIGINT,in amsg TEXT,in areceived_ts TIMESTAMP)
BEGIN
    DECLARE done,mts,Ccapture INT DEFAULT 0;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = -1;

    SELECT id,pattern,grouping,capture INTO mts,@pattern,@grouping,Ccapture FROM abuser_trigger WHERE
    amsg LIKE msg AND
    aprogram LIKE if(program='' or program is null,'%',program) AND
    afacility like if(facility<0,'%',facility) AND
    alevel like if(`severity`<0,'%',`severity`) and active=1
    LIMIT 1;

    SET @grouping = (CONVERT(CONCAT('\\',@grouping) USING utf8) COLLATE utf8_unicode_ci);
    IF @pattern REGEXP '^\\^' != '1' THEN
        SET @pattern = (CONCAT('^.*',@pattern));
    END IF;
    if @pattern REGEXP '\\$$' != '1' THEN
        SET @pattern = (CONCAT(@pattern,'.*$'));
    END IF;

    IF mts>0 AND Ccapture IS NOT NULL AND INET6_ATON(REGEXP_REPLACE(amsg,@pattern,@grouping)) IS NOT NULL THEN
        INSERT INTO abuser_incident (ip,trigger_id,counter,first_occurrence,last_occurrence)
        VALUES (INET6_ATON(REGEXP_REPLACE(amsg,@pattern,@grouping)),
            mts,1,areceived_ts,areceived_ts)
        ON DUPLICATE KEY UPDATE counter=counter+1,last_occurrence=areceived_ts;
        SELECT id INTO @incident_id FROM abuser_incident WHERE ip=INET6_ATON(REGEXP_REPLACE(amsg,@pattern,@grouping)) AND trigger_id=mts;
        CALL abuser_log_evidence(@incident_id,aid);
    END IF;
END;//


/*
 * Procedure to process old archive log entries and delete them
 */
DROP PROCEDURE IF EXISTS eproc_rotate_archive//
CREATE PROCEDURE eproc_rotate_archive()
BEGIN
  SET @archive_days=IFNULL((SELECT val FROM sysconf WHERE id='archive_keep_days'),7);
  SET @archive_limit=IFNULL((SELECT val FROM sysconf WHERE id='archive_delete_limit'),0);
  SET @use_mem=IFNULL((SELECT val FROM sysconf WHERE id='archive_delete_use_mem'),'no');

  IF @archive_days>0 THEN
	IF @use_mem != 'yes' THEN
  	  CREATE TEMPORARY TABLE IF NOT EXISTS archive_ids (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);
  	ELSE
  	  CREATE TEMPORARY TABLE IF NOT EXISTS archive_ids (id BIGINT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=MEMORY;
	END IF;

	SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
	START TRANSACTION;
	IF @archive_limit > 0 THEN
    	PREPARE choose_archive_ids FROM 'INSERT INTO archive_ids SELECT id FROM `archive` WHERE received_ts < NOW() - INTERVAL ? DAY LIMIT ?';
	   	EXECUTE choose_archive_ids USING @archive_days, @archive_limit;
    ELSE
    	PREPARE choose_archive_ids FROM 'INSERT INTO archive_ids SELECT id FROM `archive` WHERE received_ts < NOW() - INTERVAL ? DAY';
	   	EXECUTE choose_archive_ids USING @archive_days;
	END IF;
	DEALLOCATE PREPARE choose_archive_ids;
	-- Ignore ID's from entries that exist on archive_unparse
	DELETE t1.* FROM archive_ids as t1 LEFT JOIN archive_unparse AS t2 ON t1.id=t2.id WHERE t2.id IS NOT NULL;
	-- Ignore ID's from entries that exist on syslog
	DELETE t1.* FROM archive_ids as t1 LEFT JOIN syslog AS t2 ON t1.id=t2.id WHERE t2.id IS NOT NULL;
	-- Ignore ID's from entries that exist on abuser_evidense
	DELETE t1.* FROM archive_ids as t1 LEFT JOIN abuser_evidence AS t2 ON t1.id=t2.archive_id WHERE t2.archive_id IS NOT NULL;
	DELETE t1.* FROM `archive` AS t1 LEFT JOIN archive_ids AS t2 ON t1.id=t2.id WHERE t2.id IS NOT NULL;
	COMMIT;
	DROP TABLE IF EXISTS archive_ids;
  END IF;
END;//



/*
 * Procedure to process old abuser log entries and delete them
 */
DROP PROCEDURE IF EXISTS eproc_rotate_abuser//
CREATE PROCEDURE eproc_rotate_abuser()
BEGIN
  SET @archive_days=IFNULL((SELECT val FROM sysconf WHERE id='abuser_keep_days'),7);
  SET @keep_incident=IFNULL((SELECT val FROM sysconf WHERE id='abuser_keep_incident'),'yes');

  IF @archive_days>0 THEN
	CREATE TEMPORARY TABLE IF NOT EXISTS incident_ids (id BIGINT UNSIGNED NOT NULL PRIMARY KEY);

	START TRANSACTION;
   	PREPARE choose_incident_ids FROM 'INSERT INTO incident_ids SELECT id FROM `abuser_incident` WHERE `counter`=0 AND `last_occurrence` < NOW() - INTERVAL ? DAY';
   	EXECUTE choose_incident_ids USING @archive_days;
	DEALLOCATE PREPARE choose_incident_ids;
	IF @debug IS NOT NULL THEN
      SELECT t1.* FROM abuser_evidence AS t1 LEFT JOIN incident_ids AS t2 ON t2.id=t1.incident_id WHERE t2.id IS NOT NULL;
	END IF;
	DELETE t1.* FROM abuser_evidence AS t1 LEFT JOIN incident_ids AS t2 ON t2.id=t1.incident_id WHERE t2.id IS NOT NULL;
	IF @keep_incident != 'yes' THEN
	  IF @debug IS NOT NULL THEN
	  	SELECT t1.id FROM abuser_incident AS t1 LEFT JOIN incident_ids AS t2 ON t2.id=t1.id WHERE t2.id IS NOT NULL;
	  END IF;
      DELETE t1.* FROM abuser_incident AS t1 LEFT JOIN incident_ids AS t2 ON t2.id=t1.id WHERE t2.id IS NOT NULL;
	END IF;
	COMMIT;
	DROP TABLE IF EXISTS incident_ids;
  END IF;
END;//