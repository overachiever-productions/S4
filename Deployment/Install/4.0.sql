

-- note, warn that we're enabling xp_cmdshell... 
--		point to a link where we outline that it's NOT a problem. 
--			and... the link... needs to be the link that both backups and restore scripts point to... 


-- enable advanced options as necessary. (and save a 'bit value' to revert as needed)... 
-- then enable xp_cmdshell and output an ERROR... so'z people can see a 'warning' that xp_cmdshell was enabled. 


-- deploy version_info/history, other logging tables, and ... all common/utility then backup/restore scripts.