DELETE FROM interwiki WHERE iw_prefix = 'climatekg-wiki';
INSERT INTO interwiki (iw_prefix, iw_url, iw_api, iw_wikiid, iw_local) 
VALUES ('climatekg-wiki', 'http://localhost/wiki/$1', 'http://localhost/w/api.php', '', 1);
