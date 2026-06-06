SELECT (CHAR_LENGTH(old_text) - CHAR_LENGTH(REPLACE(old_text, '<span id=', ''))) / CHAR_LENGTH('<span id=') as span_count,
       LOCATE('HELLO WORLD', old_text) as hello_world_pos,
       CHAR_LENGTH(old_text) as content_len
FROM text 
JOIN content ON CONCAT('tt:',old_id) = content_address 
JOIN slots ON slot_content_id = content_id 
JOIN revision ON rev_id = slot_revision_id 
WHERE rev_id=10900;
