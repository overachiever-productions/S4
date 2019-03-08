# S4 Basics 
- File 
## Basics - Table of Contents
[toc]


[... back to parent]


## License

MIT license. free as in beer - not as in turn my projets commie/hippie. 

## Requirements
[In addition to conventions, following requirements]
- ??? 
- Only works for supported versions
- most/many (but not all) features require Database Mail configuration - as outlined in conventions below. 
- Only works with supported versions... 
- Will create an admindb
- Will enable xp_cmdshell. 


### Supported Versions
[NOTE to SELF: I've got info about some of the details below in S4 Backups and S4 restore (intros)]

- SQL Server 2008 (Partial Support: S4 Backups only - other stuff throws errors.)
- SQL Server 2008 R2 (similar to above)
- SQL Server 2012
- SQL Server 2014 
- SQL Server 2016
- SQL Server 2017  (Windows Only)
- SQL Server 2019  (Windows Only)

NOTE: On linux... some stuff just can't/won't work... yet/etc.

NOTE: azure... meh... 

NOTE: case-sensitive servers suck.. S4 isn't there yet. 


## S4 Philosophies 
[key things to know about S4... 
- **Convention over Configuration.** favors convention over configuration - but still attempts to be extensible
- **Errors and Failures - Fail Fast.** Fail 'early' in terms of config... if config of sprocs doing things isn't right... parameter validation will raise an error. 
- **Errors and Failures - Resiliency.** When doing batch operations (i.e., something against multiple similar targets/etc... )... failure in one operation usually shouldn't mean that the entire process fails/crashes/terminates... 
- **Signal vs Noise.** instead... problems are logged and or recorded, and when operation completes, any errors or isseus encountered along the way will be raised via a single message or output.
- ???? 
- etc.. 
]

## Conventions  (damn, i MAY need to put this in its own page?)
[S4 favors convention over configuration - but, enables configuration if/and/when/as needed.]

### The Benefit of Convention
[here's an example of why this is good... let's look at a sproc that does backups: 

here's a call to it with parameters all defined as needed... 

[example]

here's a call that will do the same as the above - but with defaults in place - i.e., conventions

[example - with just like 3 or 5 lines or whatever... ]

]

Of course, for all of the above to work, you'll need to adhere to S4 conventions. You don't have to... but, when you do, the defaults for S4 sprocs and operations are designed to simplify usage even more than hwat you pick up from the logic/code itself.]

### S4 Conventions
[following conventions are defined, and, effectively, expected. but if you don't want to use these conventions and/or can't... then you can 'configure' your way around them in many cases.]

### Procedure Naming
[borrows from PS... with the idea of verb-noun[phrase]]... any sprod or whatever that 'does' someting starts with verb of what it does, with a description of what it's operating against or providing... 

#### File Paths 
[S4 uses convention of trying to use defined 'default' paths defined in SQL Server (registry) for data, log, and backup. If these aren't set (or aren't valid... throw an error) and, of course, you can change these...  ]

NOTE: paths provided in S4 can have \ or skip trailing slashes in path names... (file names - obviously not)... S4 normalizes all paths... so if D:\SQLBackups is your preference, good on you; or if you prefer D:\SQLBackups\ good on you - equally (life's too short to have to remember pathing conventions).

#### Operators [TODO: hmmm ... what about using the 'default' operator - the one that's the failsafe in SQL Server Agent? - Maybe the convention is THAT then 'Alerts' by default - but you can override.]
[alerts]... 
[info / guidance / best practice on operators in general]
[s4 assumes/defaults to 'Alerts' - if you can (and want to) add this, otherwise, you'll just need to replace this with whatever else you've set up.]

#### Mail Profile [TODO: same as above - want to use the general/default profile then 'general'... and throw error if neither of those works... i.e., you'll need to overwrite.]
[general]
[same-ish as above... ]
[call out difference between profiles and accounts - and how profiles can (and should) have multiple accounts]

#### Subject Line Headings 
[or whatever I call these... ]
[but, if S4 is going to send an alert, a DEFAULT heading/subject-line will be set for you.]
[but you can overwrite this if/as needed.]


#### @PrintOnly - easy 'debug/view/customize-generated-scripts'
[all sprocs that can/will make changes or do things other than 'print details' or run SELECT queries have the option to @PrintOnly... ]
by convention, it defaults to 0. 

[NOTE: in many cases ... setting @PrintOnly to 1 will skip/bypass many of the parameter input checks... like for @Operator, @MailProfile, etc... (this is by design: since we won't be emailing... no sense in evaluating those.).]

#### Section Conventions
[these are just global conventions... other sections can/will define their own conventions and defaults in many cases ... (i.e., backups specify conventions around the notion of CopyTo ... and so on... )]
[i dunno, maybe i don't need this.]

### S4 Constructs and Parameter Values
[specialish options that override stuff... ]

#### Tokens
[place holders and such... for variety of cases. documented per each sproc they apply to... but they include]
- {0} db place holder name. 
- * ... everything else... 

#### 'Lists'
[comma separated stuff... can include * ... when defining priorities and such... ]

#### 'Modes'
[the whole idea of certain 'overloads' for many kinds of sprocs... ]
[generally, this kind of thing is a usually a bad idea(TM) in SQL Server - given how SQL Serer doesn't do great with code-reuse and how it violates separation of concerns and so on... ]
[but here... helps with DRY and helps keep code-base small - and we're NEVER deailing with huge amounts of data and/or super-complex predicates/queries that haven't been tested/optimized prior to release.]

#### 'Vectors'? TimeSpans? what ever I'm going to call them 
[NOTE TO SELF: vectors doesn't quite work with something like 3b - that's more of a range/... something]

[... durations or ranges time (time-spans?) are pain in parameters... ]
[could name things like retention or how far back to check something as @parameterNameMinutes or... whatever... ]
[instead ... S4 uses configuration of Xn - where x = int... and n is a signifier...  i.e., 4h ... 2d and or... 2b[ackups] ... ]



## Deployment
[simple installer script... designed to make install and updates seamless/easy]

### Installation and Updates
[script for latest version of S4 for each is here: [link]]... 

By running it you: 
- agree to license/terms
- will create an admindb (if it's not already created) (will create at same location/path as masterdb.)
- will enable xp_cmdshell... [link to stuff/panic about xp_cmdshell and why it is NOT a big deal]

### dbo.version_history 
used to keep tabs on which versions have been deployed. easy to verify what version you're currently on... ... 
