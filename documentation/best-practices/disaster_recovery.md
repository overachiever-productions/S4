![](https://assets.overachiever.net/s4/images/s4_main_logo.png)

[S4 Docs Home](/readme.md) > [S4 Best Practices](/documentation/best-practices/) > Leveraging S4 for Disaster Recovery

> ### :label: **NOTE:** 
> *This S4 documentation is a work in progress. Any content [surrounded by square brackets] represents a DRAFT version.*

# Leveraging S4 for Disaster Recovery

## Table of Contents
- [Section 1: Purpose](#section-1-purpose)
    - [Documentation Layout](#documentation-layout)
    - [Recommended Document Usage](#recommended-document-usage)
- [Section 2: Core Disaster Recovery Concepts and Conventions](#section-2-core-disaster-recovery-concepts-and-conventions)
    - [High-Availability vs Disaster Recovery](#high-availability-vs-disaster-recovery)
    - [Disaster Response Metrics](#disaster-response-metrics)
- [Section 3: Disaster Preparation](#section-3-disaster-preparation)
    - [Enabling the DAC](#enabling-the-dac)
    - [Monitoring and Alerts](#monitoring-and-alerts)
- [Section 4: Disaster Prevention and HA Systems Management](#section-4-disaster-prevention-and-ha-systems-management)
    - [Monitoring System Performance and Health](#monitoring-system-performance-and-health)
    - [Responding to Alerts](#responding-to-alerts)
    - [Managing HA Failover Operations](#managing-ha-failover-operations)
- [Section 5: Enumerating Disaster Recovery Resources](#section-5-enumerating-disaster-recovery-resources)
- [Section 6: Creating a Disaster Recovery Plan](#section-6-creating-a-disaster-recovery-plan)
- [Section 7: Disaster Response Techniques](#section-7-disaster-response-techniques)
    - [Part A: Hardware, Virtualization, and OS Problems](#part-a-hardware-virtualization-and-os-problems)
    - [Part B: High Availability Problems](#part-b-high-availability-problems)
    - [Part C: SQL Server Problems](#part-c-sql-server-problems)
        - [Handling Suspect and Recovery-Pending Databases](#handling-suspect-and-recovery-pending-databases)
        - [Restoring and Recovering System Database](#restoring-and-recovering-system-databases)
        - [Restoring and Recovering User Databases](#restoring-and-recovering-user-databases)
        - [Page-Level Recovery of User Databases](#page-level-recovery-of-user-databases)
        - [Point in Time Recovery of User Databases](#point-in-time-recovery-of-user-databases)
        - [Smoke and Rubble Restores](#smoke-and-rubble-restores)
    - [Part D: Disaster Response Techniques and Tasks](#part-d-common-disaster-response-techniques-and-tasks)
        - [Putting Databases into EMERGENCY Mode](#putting-databases-into-emergency-mode)
- [Section 8: Regular Testing](#section-8-regular-testing)
    - [Benefits of Regular Testing](#benefits-of-regular-testing)
    - [Testing Scenarios](#testing-scenarios)
    - [Automating Restore Tests](#automating-restore-tests)
    - [Addressing Testing Outcomes](#addressing-testing-outcomes)
- [Section 9: Maintenance and Upkeep Concerns](#section-9-maintenance-and-upkeep-concerns)
- [Section 10: Appendices](#section-10-appendices)
    - [Appendix A: Glossary of Concepts and Terms](#appendix-a-glossary-of-concepts-and-terms)
    - [Appendix B: Business Continuity - Key Concepts and Metrics](#appendix-b-business-continuity-concepts-and-metrics)

## Section 1: Purpose

> ### :bulb: **TIP:**
> Conventional IT wisdom dictates: *“If you don’t regularly test your Disaster Recovery Documentation, you DO NOT have a Disaster Recovery Plan, all you have is a DR document.”*

This Disaster Recovery (DR) documentation consists of two types of content:
- **Pro-Active Documentation.** Documentation and best-practices related to pro-active Disaster Recovery protections and preparation (i.e., an overview of protections to take and instrumentation and alerting to put into place to be pro-actively notified of disasters). 
- **Re-Active Documentation.** Documentation to be used in the case of an actual Disaster – to serve as a resource to help streamline, focus, and enable optimal responses to disasters.

### Documentation Layout
This document addresses a significant number of considerations. As such, it has been broken down into various 'sections' to help make overall management easier to navigate. 

In this document: 
- **Sections 1 - 4** focus on core concepts and techinques related to Disaster Recovery and Business Continuity.
- **Sections 5 - 7** cover re-active Disaster Recovery needs - i.e., checklists and guidance for performing various Disaster Recovery steps when dealing with disasters.
- **Sections 8 - 9** address common concerns related to change-management - and how changes to your environment can change your Disaster Recovery considerations, plans, and readiness. 
- **Section 10** provides Appendixes with additional information and insights relative to Disaster Recovery and other Best Practices related to business continuity.

### Recommended Document Usage
Prior to disaster scenarios, care should be taken to:
- Read and understand all details covered in this document. 
- Make sure that any changes to the environment, business requirements, or anything else that impacts anything covered in these documents is dutifully addressed to prevent ‘breaking changes’ from going un-defined.
- **Ensure that this documentation is regularly tested and verified.**  

When using this documentation to respond to a disaster:
1. Review Section 5 to review step-by-step instructions for preventing further data-loss or down-time and to create a Disaster Recovery Plan. 
2. Review the contents of Section 6 to obtain escalation (contact) details and gather details about the environment, server topologies, security details, and locations for backups, etc. 
3. Escalate the Disaster Recovery Plan as outlined in Section 6. 
4. Use Section 7 and any applicable appendices (Section 10) to respond to any specific details or needs while executing the disaster recovery plan.

[Return to Table of Contents](#table-of-contents)

## Section 2: Core Disaster Recovery Concepts and Conventions
This documentation makes use of two different sets of conventions to define the types of disasters that can/will be encountered and to define the metrics by which disasters are addressed AND how their impact is communicated to management (and in terms of how management and IT can use these same metrics to work towards defining acceptable amounts of down-time).

### High-Availability vs Disaster Recovery
High Availability (HA) and Disaster Recovery (DR) are two terms that share a significant amount of overlap – but while the terms may appear to be synonymous, they are quite different. 

For the purposes of this documentation:
- **High Availability.** High Availability defines the tools, techniques, and practices used to address ‘simple’ and ‘expected’ failures – such as disk, hardware, OS, and other sorts of failures and crashes that while (typically) rare, can result in negative impacts to business continuity and overall availability unless addressed in advance. ***Typically, HA attempts to provide pro-active protection against hardware and other system-level failures and typically does so by creating fault-tolerance (or redundant systems designed to ‘cover’ a single-point-of-failure).*** 

- **Disaster Recovery.** While HA typically focuses on techniques and solutions to pro-actively protect against disasters, Disaster Recovery (DR) can be pro-active as well (i.e., this documentation was written to pro-actively help with addressing disasters). ***Typically, however, Disaster Recovery is typically concerned with the techniques, processes, strategies, and skills necessary to RESPOND to catastrophes or significant outages*** – i.e., disasters which typically cannot be easily remedied by mere fault-tolerance alone – or that happen when fault-tolerant systems fail and/or won’t allow production systems to operate as expected. 

Put simply, both HA and DR systems and solutions are employed to improve availability and up-time. As such, both concerns are addressed within this documentation. 

However, in overly-simplistic terms, it is best to typically think of HA and DR as follows:
- HA Problems are typically ‘hiccups’ or ‘minor’ problems within a single data-center that can range from something like the crash/failure of a single service, component, or operating system on up to more ‘spectacular’ failures like the loss of an entire server/hypervisor. Typically, when an HA system encounters a failure, redundant systems are expected to ‘catch’ the failure, respond, and ‘stand-up’ a replacement service, component, or even host – to keep things running as optimally as possible and with the least amount of down-time AND human intervention possible. 
- Disasters and Disaster Recovery typically amount to ‘serious’ problems where either something has gone wrong with HA solutions and systems (to the point where they are compromised and/or not functioning correctly), where there’s a major problem or issue with data (that will need some sort of human interaction to resolve), or where significant or major components within a single data center have gone down (i.e., loss of the SAN or major networking infrastructure or even loss of the entire data center). Typically, but not always, response to disasters includes manual interaction with and restoration from backups and/or failover to an entirely different hosting location/data-center. 
As outlined above, responses to either HA or DR scenarios can include pro-active planning and the creation of various contingencies, but it’s typically safe to say that ‘Disaster Recovery’ is best equated with human interaction and remediation to major problems, whereas (within the scope of this document) HA is defined as a set of ‘reactive’ or automated contingencies put in place before failures occur and which can be reviewed and analyzed by humans AFTER a problem occurs rather than requiring human interaction BEFORE a system can be put back online again. 

### Disaster Response Metrics
The simplest way to describe and define outages and/or disasters and their impact on business is to focus on two key points:
- The amount of down-time incurred during the failure, outage, or disaster. 
- The amount of data potentially lost during the failure, outage, or disaster.

Ideally, disasters would never occur and/or if they did, they would never result in any lost data. However, complex systems can encounter complex errors and fail ‘spectacularly’ – to the point where a realistic, or pragmatic, approach to addressing disasters starts by acknowledging that they can happen, then setting out to minimize their potential impact. 

To help with both quantifying the potential impact of outages, and to establish a set of common concepts or terms used when responding to failures and disasters, this documentation leverages the following two terms or concepts:

- **Recovery Time Objectives (RTOs).** As the name implies, RTOs are objectives (or goals) that define how quickly recovery can/will occur after a failure or disaster has occurred. In short, RTOs are both a measure of down-time coupled with an expectation of how much down-time is ‘allowable’ for certain, different, types of failures or crashes. Obviously, the lower the number (measured in seconds or minutes), the lower the impact to business. However, different types of disasters necessitate different amounts of time for a proper response. 

- **Recovery Point Objectives (RPOs).** Also measured in terms of seconds and/or minutes, RPOs describe goals (or objectives) which define an expectation of how much DATA can be lost during various different types of crashes or outages. 

Importantly, any failure or disaster is typically going to incur both the loss of up-time AND roughly 2x the time associated with potential for lost data – which means that end-users (i.e., customers) typically get ‘hit’ with both the amount of time ‘tolerated’ for system to be down (the RTO) PLUS roughly 2x the amount of time associated with ‘tolerated’ data-loss. So, for example, if the ‘simple’ failure of an entire host/hypervisor is defined with RPOs of 20 seconds (i.e, up to 20 seconds of data-loss) and RTOs of 4 minutes, end-users can EFFECTIVELY expect to ‘lose’ around 5 minutes of availability – in the form of up to roughly 4 minutes of time where the system was lost/down, 20 seconds of lost data that they have already put into place, a few seconds to figure out what was lost, and the potential need for them to RE-INPUT any lost changes). 

> ### :bulb: **TIP:**
> *Rather than having IT personnel ‘guess’ at what would be tolerable amounts of data-loss and/or down-time during disasters, IT personnel should coordinate with Business Owners/Management to work together on establishing RPOs and RTOs – as this leaves management with a clear picture of what is possible and ensures that management realizes that there are COSTS associated with decreasing these metrics (and puts management ‘on the hook’ to collaborate with IT personnel in making sure they have the right tools, systems, and skills in place to be able to meet the objectives outlined by management).* 

> ### :bulb: **TIP:**
> *A sample matrix of stated RPOs and RTOs - against a variety of different kinds of outages and/or disaster-types in the form of a worksheet that can facilitate discussions between IT and management can be found [here](/documentation/best-practices/availability_and_recovery_worksheet.pdf).*

> ### :label: **NOTE:** 
> *Additional, extended, information on RPOs, RTOs, and other metrics used to describe and quantify ‘down-time’ and data-loss (i.e., problems with Business Continuity) is covered in [Section 10, Appendix B – Business Continuity Concepts and Metrics](#appendix-b-business-continuity-concepts-and-metrics)*

[Return to Table of Contents](#table-of-contents)

## Section 3: Disaster Preparation
Prior to disaster, care must be taken to ensure that not only are the following key concerns addressed, but that they’re also regularly checked and verified as being fully functional:

- **Viable SQL Server Backups.** A Disaster Recovery Plan is only as good as its last, viable, backup and associated backup chain.

- **Monitoring and Alerts.** Avoidable ‘disasters’ and problems like running a server out of disk or detecting problems with resource usage and load are things that can be easily automated and used to help pro-actively monitor (and then send alerts if/when necessary) as part of a comprehensive Disaster Recovery solution (by making administrators pro-actively aware of potential or pending failures and/or disasters). 

- **High Availability / Fault Tolerance.** A key component of any Disaster Recovery Plan is the attempt to AVOID as many disasters as possible by making components that are susceptible to faults or failures (such as disks, power-supplies, and even entire-servers/operating-systems, or even entire data-centers) fault-tolerant or redundant, so that ‘small’ disasters can be quickly, and optimally handled. 

An explicit goal of the functionality provided by S4 is to address all 3x of the above core business continuity needs. For more information, see: 
- [Managing SQL Server Backups with S4](/documentation/best-practices/backups.md)
 and [Managing and Automating Regular Restore-Tests with S4](/documentation/best-practices/restores.md)
- [High Availability Configuration, Monitoring, and Management](/documentation/apis.md#high-availability-configuration-monitoring-and-management)
- [Monitoring](/documentation/apis.md#monitoring)

### Enabling the DAC 
Prior to any disaster, best practices for SQL Server administration in any production environment are to enable the [Dedicated Administrator Connection - or DAC](https://docs.microsoft.com/en-us/sql/database-engine/configure-windows/diagnostic-connection-for-database-administrators?view=sql-server-ver15). 

S4 easily facilitates enabling access via the DAC by means of executing [`dbo.configure_instance`](/documentation/apis/configure_instance.md). 

> ### :zap: **WARNING:** 
> *In ADDITION to enabling access to the DAC from within SQL Server, the DAC also 'listens' for connections to SQL Server on port 1434 - meaning that you will ALSO need to enable a firewall rule on your host server if your host defaults to a locked-down configuration.* 

<div style="margin-left: 40px;">
For example, to create a firewall rule allowing SQL Server to listen on port 1434 via the Windows Firewall using Powershell, you would run the following command: 

```powershell

New-NetFirewallRule -DisplayName "SQL Server = DAC" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1434;

```
</div>

### Monitoring and Alerts
S4 provides the capability to enable pro-active monitoring and alerts on the systems and resources described in this Disaster Recovery Documentation. 

An effective component of leveraging S4 for Disaster Recovery purposes is to ensure that all of the pro-active monitoring components that are applicable to your individual environment and business continuity needs have been set up and properly configured BEFORE a disaster. 

> ### :bulb: **TIP:**
> *Care should be taken to ensure that these monitoring routines and associated alerts remain functional and periodically tested/verified to ensure viability.* ***Likewise, admins should have a rough idea of how to respond to alerts if/when raised.*** 

### Alert Recipients
*[DOCUMENTATION PENDING.]*

[NOTES: Need to link-to and address conventions for defining alert recipients via SQL Server Agent Operators - i.e., `Alerts` by default - along with links to documentation on how to update/customize if/as needed.]

[NOTES: Need to provide rationale/recommendation for having SQL Server Agent operators link to aliases as opposed to specific email addresses - as per: 

https://www.itprotoday.com/database-mail-tip-notifying-operators-vs-sending-emails
]

### S4 Alerting Inventory 
The following S4 alerting capabilities are currently available - with links to setup and other documentation specified per entry listed below.

#### Disk Space Checkups 
[Disk space checkups](/documentation/apis/verify_drivespace.md) should be set to run regularly (every 10 - 15 minutes typically makes sense - as the cost (or 'overhead') to assess availability disk-space is trivial/negligable), and will report on situations where available disk (on drives hosting SQL Server databases) drop below a specified number of GBs of free space (which can be modified by the the job) via the `@WarnWhenFreeGBsGoBelow` parameter. 

In situations where available space drops below the alerting threshold, Administrators should check Section 7 – Response Techniques, Part A – Hardware, Sub-section 1 – Problems and look for the Response Technique defined for Addressing Low Disk Space. 

#### Corruption and IO Subystem Problem Alerts

**SQL Server Alerts for Errors: 605, 823, 824, and 825.**
A core component of successfully addressing problems with database corruption is to make sure that any problems or issues that SQL Server encounters related to corruption (or possible IO subsystem/storage problems) are reported immediately. 

Happily, SQL Server makes it easy to configure alerts for specific error conditions (i.e., specific error numbers). S4's [`dbo.enable_alerts`](/documentation/apis/enable_alerts.md) can, therefore, be easily used to set up alerts for these types of problems or situations via the `@AlertTypes` parameter - when set to either `SEVERITY_AND_IO` or `IO`. 

SQL Server Alerts for specific problems related to problems with the IO subsystem (read/write failures, excessive read/write retries) as well as specific alerts for various types of database corruption are defined to be fired whenever problems are encountered. 

In most cases, alerts raised for these error numbers will signal either a disaster, a pending disaster, or a major problem that MIGHT NOT be disaster but still requires immediate attention. 

#### Severity 17+ Alerts 
In addition to being able to monitor for specific error messages, SQL Server provides the ability to monitor for different error severities (where each error raised on the server is assigned a severity (Severity 1 – 16 being considered ‘informational’ severities, and severities 17+ being considered warnings or major errors in terms of the severities). 

As such, S4 enables the creation of alerts that will notify of any errors ‘thrown’ on the server associated with Severity 17 and above – all of which TYPICALLY end up being associated with major problems or concerns on the server (such as access faults, problems with IO or memory subsystems, and/or the loss of processing and other key resources and the likes).

For setup and configuration options, see [`dbo.enable_alerts`](/documentation/apis/enable_alerts.md).

#### Backup Failure Alerts
All backup jobs are configured to both raise an alert (within the backup orchestration code itself) when a backup operation fails, and the SQL Server Agent Jobs executing the backups are also set to raise alerts if there is an error executing the backup routines. Arguably, while backup failures in and of themselves shouldn’t typically be considered a disaster, they can either disrupt or destroy all disaster recovery options (left un-addressed for a long period of time). 

Backup failures need to be sized-up and addressed quickly if/when the occur.

#### Restore Test Alerts 
While having notifications provide alerts any time there are problems with regularly scheduled backups, the sad reality is that the ONLY way to truly know if backups (of anything - not just SQL Server backups) are VIABLE is to test or restore them. 

Consequently, the steps outlined in the [Examples section of the API documentation for `dbo.restore_databases`](/documentation/apis/restore_databases.md#examples) along with details outlined in the Best Practices documentation for [Managing and Automating Regular Restore-Tests with S4](/documentation/best-practices/restores.md) should be implemented to set up regularly scheduled (i.e., nightly) restore-tests for production-level databases - which, in turn, will raise alerts if/when problems with backups are detected. 

#### Database Consistency Checks 
While configuring alerts to signal problems with [Database Corruption and IO Subsystem Problems](#corruption-and-io-subsystem-problem-alerts) is a critical part of ensuring that you can recover from problems when they're encountered by applications and end-users, but it's only a PART of the overall process of ensuring that corruption is quickly and regulary detected. 

Or, stated differently, the Corruption and IO Subsystem Alerts defined previously are a great tool for letting you know when data that's being queried or modified by end-users and/or applications has encountered corruption - but that ONLY addresses what happens with 'volatile' data - or data that's been 'recently' accessed. But what about data that gets written once and 'sits' on the server for potential days/weeks/months before being queried or accessed? 

For example, imagine that we write some data to disk at 10AM, and, by 2PM the next day, a query detects that this data is now corrupt (checksums no longer match) - that's perfect, we've quickly and correctly identified corruption - on semi-volatile data. But, what if the data was written at 10AM today (and corrupted write as it's being written), and won't be actively queried until the end of the month (say, 18 days from now)? If we 'wait' for 18 more days to detect corruption, we have two problems:

1. We may NOT (and in most cases DO NOT) have an UNBROKEN chain of FULL + T-LOG Backups stretching back 18+ days - which is what would be needed to go 'back in time' and replay all transactions from that point forward to make sure this data was recoverable. 

2. Assuming we DO have this unbroken chain (which, again, usually is NOT going to be the case), do you REALLY want to incur the time (down-time if running Standard Edition) necessary to 're-run' 18+ days of transactional operations to recover this data? 

> ### :zap: **WARNING:** 
> *Don't assume that corruption ONLY happens when data is written to disk. It CAN happen when data is written to disk, but it can also happen if/when data has been CORRECTLY written to disk (i.e., no corruption) and when no other logical operations attempt to touch or modify said data. Instead, 'perfectly good' data can be mangled when 'just sitting there - doing nothing'.*

To avoid data-disasters - where data sits idle for long periods of time without being identified as having become corrupt (until it's 'too late' to effectuate a safe recovery), best practices for SQL Server disaster protection dictate that consistency checks be regularly scheduled to help protect against corruption by surfacing problems with data corruption on a regular basis. 

> ### :zap: **WARNING:** 
> *If you value your data, determining when to run Database Consistency checks is not a question of trying to balance when to run checks vs the potential impact these checks may have on your hardware - nor is it a question of assuming that running it every X days 'or so' will be good enough. Instead, because you'll need at LEAST a FULL backup + an unbroken chain of T-LOG backups from BEFORE corruption 'happened' up until 'now', the frequency for when consistency checks should be run is tightly tied to how LONG you're keeping FULL + T-LOG backups in an unbroken chain. For example, if you're keeping FULL + T-LOG backups on-box for, say, 3 days only, then you'll NEED to run consistency checks at a **minimum** of roughly every 2 days. (Yes, technically, you've got 3x days' worth of 'coverage', but don't forget that consistency checks are a size-of-data operation and IF you find any problems, you'll need to give yourself a bit of a buffer to respond/etc. - or, in other words, if you assume 3 days = 72 hours, running consistency checks roughly every 3 days would / could put you in a situation where 5 hours into a consistency check, you've now 'crossed' your 72-hours' worth of coverage and are now in 'hour 74+' since corruption happened - at which point, you're hosed). Granted, off-box backups/copies can/should 'stretch' a bit longer than what you're keeping on-box - so if you're only keeping 72 hours' worth of backups on-box, you COULD (in theory), use off-box backups to respond to disaster - but you'll need to copy those backups back on-box and/or make them available - i.e., it's just better/easier to stay well 'inside' the retention windows you've established for on-box backups than trying to 'scramble' if/when you've been a bit 'lax' with your verification windows.* 

While SQL Server provides solid tools for database consistency checks (i.e., DBCC CHECKDB and 'friends'), S4 'extends' and simplifies this functionality via [dbo.check_database_consistency](/documentation/apis/check_database_consistency.md) - which offers 3x primary advantages over setting up checks with DBCC CHECKDB directly: 
- It enables easy execution and targetting of all and/or specific databases. 
- It is correctly optimized to include the `WITH` `NO_INFOMSGS` and `ALL_ERRORMSGS` flags (which are critical to being able to properly 'size-up'/evaluate and respond to corruption when it occurs)
- It CAPTURES all outputs of DBCC CHECKDB while it is being executed and sends those details out as part of the alerts it will raise/send when it detects corruption. 

### High Availability Systems 
Another key component in ensuring proper business continuity is to properly leverage Highly Availabile architecture and solutions when applicable. While not exhaustive, the following list outlines some of the key components and solutions that can be leveraged by SQL Server systems to improve overall business continuity:
- **Host System Redundancies.** This includes both redundant components (power-supplies, backplanes, etc.) with physical hardware hosts as well as virtualization capabilities - designed to remove single-points-of-failure at the OS/Host level.
- **Storage Redundancy.** Can include SANs for storage redundancy as well as 'fabric' and/or redundant connectivity to storage. 
- **System and Workload Redundancies.** For SQL Server systems, this can include AlwaysOn Availability Groups and Mirroring - or AlwaysOn Failover Cluster Instances. It can also include solutions like log-shipping, vSphere HA, and even 'cold' failover servers as well - all of which are designed to make 'compute' capabilities fault tolerant and redundant.
- **Site Redundancies.** Arguably, site-redundancy blurs the lines between High-Availability and Disaster Recovery, but  the availability of a secondary data-center represents the highest form of fault-tolerance and is commonly refered to as Remote Availability.

### Backups
While High-Availability systems and solutions can and will make key server and/or even database components more redundant and fault-tolerant (i.e., more redundant and less likely to ‘go down’), High-Availability Systems are NOT a suitable replacement for Disaster Recovery requirements. 

Or, put more simply, there are some situations (physical and logical corruption) where even having multiple copies of mission-critical database synchronized between one or more data-centers cannot and will not protect against situations where data might be destroyed or ‘messed up’ on one server/location and then more or less instantly replicated to other ‘redundant’ systems – thus creating ‘bad’ data in multiple locations. 

**As such, the ONLY solution for addressing issues with corruption is to have regular (and regularly tested) backups that meet RPO and RTO requirements.** 

[Return to Table of Contents](#table-of-contents)

## Section 4: Disaster Prevention and HA Systems Management
A key part of protecting against disasters, is making sure that highly-available systems remain healthy and problem-free. As such, regular health-checkups and monitoring as well as responding to alerts and addressing any warnings or monitoring errors is a key part of keeping systems healthy – and thus helping prevent the potential for disasters. 

### Monitoring System Performance and Health
[TODO: outline high-level health-checks and key indicators to monitor on regular basis (event logs and other core metrics - especially those related to DR.)]

### Responding to Alerts 
[TODO: GENERALIZED recommendations and techniques for how to respond to DR-related alerts when they occur - along with step-by-step instructions as needed and/or links into specific remediation techniques (in section 7). 

Also. Provide links/guidance on how to set up alert filtering for Severity 17+ errors and recommendations AGAINST any type of mail-box level rules to 'squelch' alerts (i.e., alert filtering at the server is how to do this - otherwise risk missing key alerts).]

[Return to Table of Contents](#table-of-contents)

## Section 5: Enumerating Disaster Recovery Resources 
A key requirement for responding to disasters in an optimal fashion is to clearly catalog and document resources needed for disaster recovery BEFORE disasters strike. Key resources needed to navigate disasters include things such as clearly defined locations for disaster recovery documentation, access to any/all security details needed for your environment, detailed inventories of server-locations and access-details + information about the locations of backups, the names and contact information for applicable team-members, support personel, management, and contact info for hosting companies and/or hosting-support contacts - among others. 

While non-exhaustive, the following section outlines two high-level sets of resources (SQL Server/Technical Resources and Business/Organization Resources) that should be reviewed and evaluated for inclusion in any real-world Disaster Recovery Plan.  

> ### :bulb: **TIP:** 
> *The worst time to assemble this is during a disaster - in fact, at that point 'assembly' is too late - you'll be incurring additional down-time.*

### SQL Server Resources
- **Basic Server-Level Details.** IP Addresses/Server Names etc. per each SQL Server should be documented/defined along with high-level details about where additional security information for elevated access (to SysAdmin, certs, etc.) can be found should be documented prior to disasters.

- **Inventory of Backup Locations.** On-box for addressing problems with corruption and inventories of off-box backups for hardware/site-wide disasters and/or smoke-and-rubble scnenarios. 

- **Hosting and Hosting/Account Details.** For some disasters (especially those involving hardware failures of any kind), correspondence with your hosting provider may be essential. Part of a solid DR plan is to ensure that everyone who needs access has (up to date access) and/or can be cleared for appropriate 'admin-level' access in the case of a disaster if needed. 

- **Support Contacts.** In addition to the above, make sure that contact and security/access information for interaction with your hosting company and their emergency support personnel is available to eveyone as needed. 

- **Permissions Elevations Processes/Documentation.** Permissions and/or Locations + Access Instructions for SysAdmin credentials or other elevated permissions that will be needed by anyone OTHER than standard/regular DBA if/when disaster occurs during time that 'standard DBA' can not be reached. [Notes here about potential need to audit access to these resources.]

- **Last Successful Restore Test Details.** For most disaster scenarios, access to metrics showing typical restore/recovery times for production databases + outcomes of regular testing can help remove significant 'guess work' from DR equations. S4 helps facilitate this via metrics stored in `dbo.restore_log` when regular restore-tests are automated via `dbo.restore_databases`. 

- **Certificates and Other Security Details.** For smoke and rubble DR scenarios, it may be necessary to restore TDE or Backup-Encryption certificates BEFORE being able to restore SQL Server backups into a NEW environment. If these aren't securely stored in an accessible/known location BEFORE a disaster strikes, it may be too late to recover at all - otherwise, if recovery is possible, it will certainly be slowed as those responding to the disaster have to 'hunt down' these resources. 

- **Server Configuration Settings.** For smoke and rubble DR scenarios, details about your FORMER SQL Server instance's configuration should be on hand along-side backups as a means of helping ensure that the new server you stand up is running the same configuration settings. S4's `dbo.export_server_configuration` can be used to set up regularly-scheduled 'dumps' of this information for DR purposes. 

- **SQL Server Logins.** For smoke and rubble DR scenarios or some DR scenarios involving the loss of the `master` database, having a backup of SQL Server Logins defined on your SQL Server instance can be a critical component of restoring in a timely fashion. [Note here about how how, obviously, access to this information needs to be guarded in sensitive environments. ] S4's `dbo.export_server_logins` can be used to set up regularly-scheduled 'dumps' of this information to ride 'side by side' with backups for help during disaster recovery scenarios.

### Business Resources
- **Defined RPOs and RTOs.** RPOs and RTOs should be defined well in advance of disasters - and can be defined by means of the [Availability And Recovery Worksheet](/documentation/best-practices/availability_and_recovery_worksheet.pdf) - which, while not exhaustive, can/will help facilitate discussions between technical and leadership teams to help ensure that business priorities are clearly defined for technical team-members (as well as to ensure that technical teams have been provided with the proper hardware, licensing, and skills/training needed to meet business continuity requirements).

- **Call Trees and Escalation Rules.** [Need information about technical resources (people) who should be looped in to respond to permutations/problems, call-bridges or other conventions used during DR/all-hands-on-deck scenarios, and contact information for management/leadership along with clear definitions of any internal rules or conventions necessary for determining how to escalate business continuity problems/disasters to leadership AND support personnel.]

[Return to Table of Contents](#table-of-contents)

## Section 6: Creating a Disaster Recovery Plan
While there is significant overlap between a disaster recovery plan and the S4 documentation outlined on this page, the S4 documentation provided here is NOT a disaster plan. Instead, this document provides a list of best-practices associated with addressing disasters (especially when using S4) along with step-by-step guidance on how to respond to specific SQL Server Disaster scenarios. 

Further, it's again important to stress that a document (by itself) is not a Disaster Recovery Plan - instead, Disaster Recovery Plans are documents accompanied with regular testing and validation. 

As such, to create your own Disaster Recovery Plan, you'll need to review the recommended resources to assemble from [Section 5: xxx ] of this document and:  
- Assemble an explicit DR plan that's unique to your EXACT business needs
- Validate this plan with any/all persons who will have a role to play in implementing this plan.
- Ensure that your own disaster recovery plan stays regularly-tested and up-to-date (as recommended in [Section 8: Regular Testing](#section-8-regular-testing) and [Section 9: Maintenance and Upkeep Concerns](#section-9-maintenance-and-upkeep-concerns)

### Typical Milestones to Address When Creating Disaster Recovery Plans

#### A. Start by Establishing Priorities. 
Define what is more important to your business: 
- the consistency (or correctness) of your data
- or overall uptime

In MOST environments, data-consistency is a much higher concern than uptime - but not all environments, workloads, or databases are tyhe same. 

**Start by making sure that your Disaste Recovery Documentation CLEARLY specifies business priorities - broken out by Product/Server/Database if/as needed.**

#### B. Define RPOs and RTOs
RPOs and RTOs go hand-in-hand with business priorities. Or, more specificially, business priorities 'inform' RPOs and RTOs - to the point where these SLAs are merely 'measures' or representations of actual business needs. 

Again: IF AND WHEN NECCESSARY, create different RPOs and RTOs for different workloads/servers, products, and or databases - and make sure that any and ALL differences are clearly documented as part of your business' actual Disaster Recovery Plan.

#### C. Address Environment Access and Security
Determine exactly what kinds of security concerns are typically associated with your production environments - and how you'll address those needs during a disaster recovery scenario. For MOST organizations and most SQL Server workloads, responding to a disaster obviously requires full-blown SysAdmin permissions. If you're going to allow 'junior level' members of your team to 'step in' and be part of the Disaster Recovery process if/when more senior-level engineers are not available, how are you going to address elevation of permissions? (One common technique is to keep SysAdmin-level credentials securely stored in an audited location - i.e., the equivalent to keeping 'keys' sealed in an envelope - in case of a disaster, the envelope can be 'opened' with permission and used by whoever needs them as long as a process for REVOKING those keys 'after the fact' exists and has been clearly mapped out).

#### D. Determine Disaster Recovery Roles and Participation
Make sure to address who can/will be responsible during db-level DR scenarios. A 'ranked' or prioritized list is usually the best option. Ensure that everyone involved is comfortable with their 'placement' and potential roles on the list. 

Ensure that EVERYONE on the list can access security info and details in the case of an emergency. 

#### E. Ensure Audited Escalation of Access to Security Instruments
SysAdmin access into a SQL Server during Disaster Recovery scenarios is usually just 'the tip of the iceberg' that can/will be NEEDED when responding to a disaster. Access to off-box/off-site backups, access to hosting-company personnel and/or support services at the hosting level, along with the need for access to certificates, login details (for application and user logins who may need to be rebuilt/recreated), and a number of other ELEVATED permissions are going to be needed to recover from non-trivial disaster scenarios. 

As such, the only REAL way to ensure that all permissions required for successfully responding to a wide variety of different types of disasters (simple emergencies on up to full-blown 'smoke and rubble' scenarios) is to both, a) ensure that 'junior members' of the Disaster Recovery team work through actual Disaster Recovery test scenarios to ensure they have necessary security access, and b) ensure period, continued, testing by those with 'lesser privilege' to ensure that any changes to your environment and workloads over time do NOT create 'surprises' that might prevent anyone with anything less than 'Full-Blown SysAdmin' access to recover. 

#### F. Create an Inventory of Disaster Recovery Resources
Using the recommendations outlined in [Section 5: Enumerating Disaster Recovery Resources ](#section-5-enumerating-disaster-recovery-resources), outline the resources specific to your organization that will be required for smooth management of disaster scenarios. Specifically, you'll typically want to address: 
- RPOs and RTOs / Business Directives.
- Calling Trees and/or (ranked) lists of personnel who can/should be notified and tasked with addressing disaster recovery responsibilities. 
- Clearly defined escalation rules for when, where/how management and/or (customer-facing) support personnel should be notified and/or involved. 
- Conference Bridges and/or recommendations for optimizing communication. (Avoid communications mechanisms that involve typing - engineers and personnel working on a fix don't need to be distracted with 'updating the board' every few minutes with their progress via slack/etc.)
- Detailed Environment information (hosting details, server IPs/names and the locations of backups, etc.)
- Detailed steps on how to escalate permissions if/as needed. 
- Links to detailed, step-by-step checklists and/or response techniques (i.e., those outlined in Section 7 of this document) that can be used to help troubleshoot specific problem scenarios when responding to disasters.

#### G. Validate Your Disaster Recovery Plan Through Testing
Again, a Disaster Recovery Plan that only exists on paper isn't a disaster-recovery plan, it's a document (that typically falls well-short of being able to provide the full degree of guidance needed to smoothly address disasters). 

As such, the most important part of any Disaster Recovery plan is the TESTING and refinement/improvements that go into the process of converting the 'paper' version of a plan into an actually viable resource or 'checklist' that can then be used when responding to true disasters. 

Or, in other words, to create a truly viable Disaster Recovery Plan, you'll likely need to run multiple, initial, tests to address a variety of different disaster scenarios to ensure that your plan (documentation, lists of resources and priorities/escalation techniques, etc.) all allow you to meet business needs as expected. 

Stated differently: PROBLEMS will occur during Disaster Recovery Testing - but, that's entire POINT of creating a Disaster Plan - doing so let's you identify (and address) those problems "before it's too late". 

#### H. Create and Schedule a Timeline for Regular Testing and Follow-Up 
Once your Disaster Recovery Plan has been validated and meets your needs, you'll need to periodically test your Disaster Recovery plan (every month is ideal, but every quarter can make sense for non-volatile environments where there's not a lot of change) to ensure that security changes, storage optimizations, and/or other major (or even minor) business initiatives and changes that might negatively impact disaster recovery procedures haven't managed to 'sneak breaking problems into play' without being noticed. Or, stated differently: even the best Disaster Recovery plan, when left un-tested over time, will gradually become non-viable due to environmental changes and modifications - as such, the worst time to figure out the 'cost' of those changes relative to Disaster Recovery is when addressing a disaster. A better option is to periodically validate and work through hiccups/issues as they crop up so that 'churn' is minimized. 

#### I. Establish Periodic Re-Evaluations of Business Priorities
Every year or so, re-evaluating business priorities (such as RPOs and RTOs) can help to both better match expectations between engineering teams and management AND decrease the potential cost associated with data-loss and/or down-time associated with disasters. 

[Return to Table of Contents](#table-of-contents)

## Section 7: Disaster Response Techniques
The following section provids detailed instructions for addressing specific tasks and operations when working through Disaster Recovery efforts. 

> ### :bulb: **TIP:**
> *[Tip here about least-destructive approaches typically being preferred - unless otherwise determinied and defined via explict DR plan details from Section 6.]*

### Part A: Hardware, Virtualization, and OS Problems 
*[DOCUMENTATION PENDING.]*

### Part B: High Availabililty Problems 
*[DOCUMENTATION PENDING.]*

### Part C: SQL Server Problems 
The following sub-section outlines step-by-step instructions and best-practices for addressing specific, SQL Server related, disaster scenarios and tasks. 

> ### :bulb: **TIP:**
> *Don't overlook the 'power of backups' when addressing any database-level Disaster Recovery scenario with SQL Server. Or, stated differently, since a KEY component of addressing disasters is to protect against the destruction of MORE data through 'accidental' moves or 'mistakes' during the recovery process, don't forget that (while it typically will take a bit more time to test/evaluate), you can FREQUENTLY 'test' anything that might otherwise be destructive to production data against a COPY of one of your 'distressed' databases FIRST. This technique is ESPECIALLY helpful when addressing some types of corruption.* 

> ### :bulb: **TIP:**
> *When assessing the scope or nature of particular disaster scenarios, it's always a best-practice to [Check the SQL Server Logs](#checking-the-sql-server-logs) before commiting to any plan of action.*

#### Physical Database Corruption 
[not a matter of if, but of when. nature of corruption... + make sure to read/review ALL docs below and during DR scenarios - do NOT 'jump the gun'.]

**Addressing Physical Database Corruption**  
Physical corruption will usually manifest either in the form of alerts being thrown from SQL Server about Errors 823, 824, 825 (when [enabled](#corruption-and-io-subsystem-problem-reports)) or due to errors or other problems encountered when working with SQL Server.

Should you encounter physical corruption:

**A. Carefully review ALL OF THESE INSTRUCTIONS Before Proceeding further.** Reviewing the documentation below will take 5-10 minutes. On the other hand, making a MISTAKE by not fully understanding how to correctly deal with corruption (i.e., not knowing your options and/or how best avoid destructive operations or common mistakes that can make things worse) typically incur much longer to address and/or can result in the NON-RECOVERABLE LOSS of business data. 

**B. DO NOT Reboot or Restart your server.** While some weird Windows issues will go away by rebooting the box, the presence of corruption will NOT go away if you reboot your server. Instead, it’s VERY possible that a reboot will actually make things MUCH worse as it may act as the means for causing SQL Server to take your database offline and render it SUSPECT – making it MUCH harder to deal with than it might otherwise be.

**C. DO NOT attempt to detach/re-attach your Databases.** As with the previous point, this is an absolute worst practice (no matter WHAT you might have read in some forums online). Detaching and re-attaching your database when corruption is present is almost certainly going to make recovery MUCH harder.

**D. Determine the Nature and Scope of the Corruption BEFORE Attempting ANY Repairs.** If you’re getting IO errors (823, 824, 825 errors) from SQL Server, then you may be at the cusp or leading edge of running into problems with corruption. As soon as possible, run

```sql 

DBCC CHECKDB([yourDbName]) WITH NO_INFOMSGS, ALL_ERRORMSGS

```

to verify if there are problems. Or, if you’ve found problems by means of regular checks or backups, make sure to evaluate ALL of the error messages returned and document or save them to a safe location somewhere (i.e., copy/paste to notepad or save as a .sql file as needed).

**E. Consider re-running DBCC CHECKDB if there is Only a Single or Minor Problem Reported.** Yes, this sounds lame and even superstitious, BUT in some _very_ rare cases if you’ve just encountered a minor bit of corruption (i.e. just one or two errors) you can actually re-run DBCC CHECKDB and the corruption will have disappeared – simply because SQL Server wrote to a bad spot (or the ‘write’ was ‘mangled’) and SQL Server was able to ‘recover’ transparently, and then write to a new location, or execute a write that ‘completed correctly’. 

Such scenarios are VERY rare but do happen. Care should be taken in these kinds of scenarios too to watch for a pattern – because while one instance of corruption here or there is sadly to be allowed/tolerated/expected, multiple problems over a short period of calendar time typically indicate a pattern of systemic problems and you need to start contemplating hardware replacement as needed. Otherwise, IF you want to take a chance that this is going on and you’re working with a small database, the factors to consider here are that if you can re-run checks quickly, it may be in your best interest to TRY this option – but don’t HOPE too much for problems to magically disappear. 

**F. Size Up Corruption and Remediation Options BEFORE doing ANYTHING.** Otherwise, when you do run into problems, make sure to WAIT until DBCC CHECKDB() has successfully completed. There are simply too many horror stories out there about DBAs who ‘jumped the gun’ at the first sign of trouble and either DESTROYED data unnecessarily or who INCREASED down-time by responding to SYMPTOMS of corruption instead of root-causes. Accordingly, make sure you review EVERY single error after SQL Server completes reporting about errors because in some cases the ‘screen’ may be chock-full of red error messages about corruption here and there in various pages, but you might find out at the end of the check that almost all of these errors are caused by a non-clustered index that can be simply dropped and recreated.

Don’t jump the gun.

Likewise, some forms of corruption are simple issues where the meta-data used by SQL Server to keep track of free space and other ‘internals’ get a bit out of ‘sync’ with reality – and in these cases SQL Server may tell you that you can safely just run `DBCC UPDATEUSAGE()` or another operation to CLEANLY and EASILY restore from corruption without incurring any downtime OR losing any data. 

Again, size up your options accordingly – and after you have all of the facts.

AND, the upside of ‘getting lucky’ with this seemingly feeble attempt is that you ALWAYS want to 100% size up the specifics of corruption whenever it occurs – as in think of the old adage: “measure twice, and cut once”.

**G. Try to obtain a tail-of-the-log backup.** If you've detected problems with corruption, you need to ensure that you correctly capture/back-up any transactions still in your transaction-log to protect against the possibility of something possibly (though usually very unlikely) going wrong during repair options. To do this, follow the instructions for [Creating a Non-Destructive Tail-of-the-Log Backup](#non-destructive-tail-of-log-backups).

**H. Determine Your Planned Recovery Strategy.** [Four main options in terms of recovery... listing best to worst in terms of order: ]

- **Execute REPAIR REBUILD or UPDATE USAGE if/as recommended.** Both options are non-destructive and will TYPICALLY result in the least amount of time needed to recover full operational status and data. 

> ### :label: **NOTE:** 
> *In many cases when corruption is minimal, SQL Server might inform you that the `REPAIR_REBUILD` option may be a viable approach to recovering data. If this is the case, or if you just want to ‘check’ and see if it will work, you can safely run `DBCC CHECKDB([yourDBName]) WITH REPAIR_REBUILD` with no worries of data loss. The only thing you stand to lose would be TIME – meaning you MUST put the database into `SINGLE_USER` mode to execute this option. So, if you think this has a potential to correct your errors, it’s a viable approach. If SQL Server indicated something more severe (that requires the use of backups or repair options that require data loss) then running this will JUST waste time.*

> ### :zap: **WARNING:** 
> *Don't confuse `REPAIR_REBUILD` with `REPAIR_ALLOW_DATA_LOSS` - these options are CLEARLY and perfectly named for a reason - as the last can, does, will allow for data loss.*

- **Execute a Page-Level Restore if possible.** If you’ve got full-blown corrupt data within a few pages (as opposed to being in indexes that could be recreated), then you’ll be able to spot those by querying msdb’s suspect pages table, like so:

```sql

SELECT * FROM msdb..suspect_pages
GO

```

Then, from there, it’s possible to effectuate a page-level restore from SQL Server using your existing backups. And what this means is that you’ll instruct SQL Server to ‘reach in’ to previous backups, ‘grab’ the data from the pages that were corrupt, and then REPLACE the corrupted pages with known-safe pages from your backups. 

MKC: TODO: i need to re-evaluate the info below ... against LARGER databases ... think I might have written the 'tip' info below for a specific client in some client-specific docs... 

> ### :bulb: **TIP:**
> *If the steps outlined above point to needing a page-level restore – then you can typically count on that taking 5-10 minutes or so – under decent circumstances – and it’s a very complex set of operations. As such, you may be much better served by simply failing the problem database over (especially if you’re able to obtain a tail-end backup).* 

More importantly, since any operations since your last backup will also have been logged (assuming FULL recovery and regular FULL/DIFF + Transaction Log backups), you’ll be able to ‘replay’ any changes against that data by means of replaying the data in the transaction log. 

(For more information on how this works, see the following video.) As such, make sure to back up the ‘tail end’ of your transaction log BEFORE beginning this operation.

- **Execute a Full Recovery.** If there are large numbers of suspect/corrupted pages (i.e., so many that manually recovering each one would take longer than a full recovery) or if critical system pages have been destroyed, then you’ll need to execute a full recovery. As with the previous operation, make sure you commence this operation by backing up the tail end (or non-backed up part) of your current transaction log – to ensure that you don’t lose any operations that haven’t been backed up.

- **Consider using REPAIR_ALLOW_DATA_LOSS if all Other Hope is Lost.** Using this option WILL result in the loss of data so it’s not recommended. Furthermore, if you’re going to run this option, Microsoft recommends that you initiate a full backup BEFORE running this option as once complete you have no other option for undoing the loss you will have caused.

As such, that begs the question: “Why would you want to use this technique?” And there are two answers.

**First**, you would use this technique IF you had no existing backups that you could use to recover from corruption otherwise. Therefore, don’t let this ever become a need – by making sure you always have viable backups.

> ### :bulb: **TIP:**
> *If you care about your data, `REPAIR_ALLOW_DATA_LOSS` is a terrible option. As such, if you've found yourself in the unenviable position of entertaining this option, you may want to create a support ticket with Microsoft. Sadly, Microsoft doesn't have a magic wand that can/will make up for your lack of backups but they do have teams of engineers adept at working through this particular disaster scenario and MAY (or may not) have some additional experience, insight, and tools other than what is publically available and supported.*

**Second**, there are some EDGE cases where SOME databases might actually FAVOR uptime over data-purity (meaning that these kinds of databases would prefer to avoid down-time at the expense of data-continuity or purity) and in cases like this there are ADVANCED scenarios where the use of `REPAIR_ALLOW_DATA_LOSS` might be acceptable (assuming you understand the trade-offs). And for more info on these kinds of scenarios, or where this would make sense, take a peek at my previous post where I provide a link to a Tech Ed presentation made by Paul Randal showing some of the raw kung-fu moves you’d need to pull off correction of these sorts of problems – assuming you felt you were in a scenario where you favored up-time over correctness.
]

**I. Evaluate the Option to Validate Repair Options in a Test Environment First.** 
Once you've evaluated your options... ... 

In environments where the accuracy of data is more important than up-time, you'll want to test or validate ANY options you've identified for corrective actions within a 'test environment' first. This test environment can be a dedicated testing server OR your production server - anywhere that you can spin-up a RESTORED copy of your database (corruption is 'copied'/preserved within backups) - so that you can test non-destructive options in a less forgiving environment/database than your primary production database. 

Yes, this will probably take longer in most cases than just executing your changes in production. Then again, if you screw something up in production, THEN which approach ends up taking longer? (Personally, I ALWAYS approach every recovery operation in looking for any options that leave me with INCREASED fall-back options and capabilities as I move forward with remediation efforts.)

J. **Verify Correction.** Once you've executed your chosen/optimal recovery operations (ideally, first in a test/sandbox environment, then in production), VERIFY that your efforts/operations have CORRECTED the problem. Depending upon WHERE original detected corruption is/was... you can run DBCC CHECKTABLE() with [commands here] if you're sure that the problem was isolated to one or more tables only, or ... if  needed, run DBCC CHECKDB. 

> ### :bulb: **TIP:**
> *It usually makes the MOST sense to run checks BEFORE returning a db back into production. BUT, if you've verified that your repairs worked against a TEST/RESTORED-COPY database and you then repeated those steps in production and didn't see any reason to doubt there was a potential problem, you CAN (in some environments - but not in others) use your best judgement to determine if you want to 'release' the database back to users WHILE re-running/re-verifying that all corruption has been cleaned up. Making this decision is a 100% judgement call and should typically be made in conjunction with management/leadership - i.e., explain the pros/cons and let them make the call or weigh-in with any concerns for or against. And, if data-accuracy is your top concern (and up-time, while obviously important, is a distant secondary concern), then the answer is simple: validate repairs/correction BEFORE releasing the database back into production use.*

**J. Initiate New Backup Chain.** Once you've verified that you're corruption free, 1) congrats, 2) it's time to kick off a new backup chain. Technically speaking, depending upon WHEN and WHERE the corruption happened, you MAY be 'fine' with just a DIFF backup. But, the reality is that you've likely just 'hit the disks' and system resources HARDER with the DBCC checks and/or any repair operations that you've JUST done than what you'll typically incur with anything but really massive databases (2TB or larger - depending upon hardware) to the point where the most logical option in the vast majority of scenarios is simply to kick off a new, FULL, backup of your database - so that you've now got a corruption-free backup-chain going forward. 

#### Handling Suspect and Recovery-Pending Databases 
Sometimes, during the SQL Server Database Recovery Process (such as during startup – see the terms and definitions section for more information) when SQL Server is ensuring that data in data files is correctly and transactional consistent with data in the log files, it may run into a problem during this validation process. When this occurs, the database cannot be verified as being transactionally consistent or not, and will typically be marked as ‘Re
NONcovery Pending’ if SQL Server can’t access the log files (or other files) or as ‘Suspect’ if there’s a problem or error that is encountered when running through the recovery process. 

> ### :bulb: **TIP:**
> *In the case of ‘Suspect’ Databases, the SSMS Object Explorer will typically display a database that is Suspect as follows:* 

> ![Example of a Suspect database](https://assets.overachiever.net/s4/images/disaster_recovery/suspect_dbs_ssms.gif)

> *Whereas, with a database that is in ‘Recovery Pending’ mode will commonly look as follows (where the option to ‘expand’ details on this database is just missing):*

> ![](https://assets.overachiever.net/s4/images/disaster_recovery/recovery_pending_ssms.gif)
    
> *And, if you try to pull up properties of a database in ‘Recovery Pending’ Mode, or try to ‘drill into it’ you’ll simply run into either a SINGLE ‘general’ page for properties and/or won’t be able to access the database at all.* 

To determine exactly which state a database is in, run the following: 

```sql 

SELECT 
    [name], [state_desc] 
FROM 
    sys.databases;

``` 

and look for any databases listed as not being ONLINE. 

**RESPONDING TO SUSPECT or RECOVERY PENDING DATABASES**

If you encounter a SUSPECT or database or a database in RECOVERY_PENDING:

A. :zap: **Do NOT attempt a restart of the server or of SQL Server. Doing so will typically make this situation much worse.** 

B. :zap: **Do NOT  attempt to detach/re-attach the database – you’ll potentially lose all transactions that haven’t been backed up in the transaction log – and stand to potentially lose the transaction log entirely.** 

C. **DO attempt a (non-destructive) tail-of-the log backup before you do anything else.** 

D. Once a tail-of-the-log backup is complete, try to ascertain why the database is suspect or marked as `RECOVERY_PENDING`. 
  
<div style="margin-left: 40px;">
Databases are usually marked as `SUSPECT` or `RECOVERY_PENDING` for one of two reasons. 

Either **a)** there’s some sort of problem with the underlying drives such that SQL Server can’t see or ACCESS either the data file or (most commonly) the log file – and therefore isn’t able to properly execute the Recovery process – in which case the database will be marked as RECOVERY_PENDING. The error log, however, won’t actually mention this specifically – instead, it will merely reference problems with opening/accessing the log or other files as per the screenshot below:

![](https://assets.overachiever.net/s4/images/disaster_recovery/file_activation_problem.gif)

OR, **b)** some sort of corruption occurred due to the fact that the database was in the process of being written to if/when SQL Server or the host OS crashed and there will be messages similar to the following in the SQL Server logs – indicating that corruption was encountered and the database is now suspect.  

![](https://assets.overachiever.net/s4/images/disaster_recovery/db_is_suspect.gif)

Typically, situations where files/data are not accessible is the most common cause for databases being marked suspect and if you check the SQL Server logs you may be able to see additional details on what is causing the problem – and fix or address those issues. (Databases can also be marked as suspect in cases where SQL Server was running through recovery OR a rollback operation and encountered corruption in a data page somewhere because, at this point, SQL Server can’t ‘revert’ or ‘roll forward’ any operations as needed.)

</div>

E. To check the logs for more insight, see [Checking SQL Server (Error) Logs](#checking-sql-server-error-logs) in PART C of this documentation below. 

F. If you’re dealing with a RECOVERY_PENDING database and you believe that you’ve corrected whatever underlying IO problems were causing the original problem, you can attempt to simply bring the database back online, with the following command: 

<div style="margin-left: 40px;">

```sql 

ALTER DATABASE [dbNameHere] SET ONLINE;
GO

```

If this command works, the database will either be switched to ONLINE or RECOVERING – depending upon how many transactions need to be reconciled. 

If this command/operation doesn’t work, then you haven’t addressed the underlying issue, and the error messages that SQL Server outputs may help you address these issues. 
</div>

G. Otherwise, if you’re not able to figure out exactly why the database is SUSPECT (or stuck in RECOVERY_PENDING) then you have two or three options available – depending upon your environment.

<div style="margin-left: 40px;">
First, if you’ve got Mirroring/AlwaysOn Availability Groups or Log Shipping available, you can look at failing over to your secondary server. 

However, just be aware that in the case of Log Shipping, you’ll want to try and obtain and apply a tail-of-the-log backup before failing over. 

Otherwise, if you don’t have a secondary server available, you have two remaining options: Simply overwrite the existing database with a backup or attempt to put the database into `EMERGENCY` mode to try and ascertain the problem - with the caveat that this approach (setting your database to `EMERGENCY` mode should usually only be done as a 'last ditch' effort.)
</div>

H. Regardless of which option (restore-in-place or attempt `EMERGENCY` mode with all of its caveats and potential negatives) you decide to use you will want to (again) **make sure you have a [non-destructive tail-end-of-the-log backup](#non-destructive-tail-of-log-backups) before proceeding.** 

I. Then, in the case where you decide to simply overwrite the database with backups, just make sure to apply the most recent FULL backup, the most recent DIFF backup (if they’re being used) and all T-Log backups (since either the most recent of the FULL or DIFF backup) along with the tail-of-the-log backup. 

J. Or, if you opt to force the database into EMERGENCY mode, you’ll then potentially be able to run DBCC CHECKDB() against the database to try and ascertain exactly what kind of damage you are dealing with and how to address it. 

<div style="margin-left: 40px;">

> ### :zap: **WARNING:** 
> *Setting a database into `EMERGENCY` mode should ONLY be done as a last-ditch effort to recover data.* 

To set your database into `EMERGENCY` mode, follow the instructions for [Putting Databases into EMERGENCY Mode](#putting-databases-into-emergency-mode) in PART B of the documentation below. 

> ### :bulb: **TIP:**
> *In most production scenarios, you’ll be better served by simply overwriting your database with backups if/when they becomes SUSPECT or locked in RECOVERY_PENDING mode IF you can't recover it by the means outlined after you’ve done all of the troubleshooting listed above.* 

</div>

#### Restoring and Recovering System Databases
Restoring SQL Server's system databases (`master`, `model`, `msdb`) can be a bit more difficult than restoring user databases. 

**Restoring the `master` Database**  
To restore the `master` database, you will have to: 
- Shut down SQL Server if it is already running
- Start SQL Server in Single-User Mode (i.e., the master database is key to core SQL Server functionality and can't be restored/overwritten unless the engine is running in a specialized state). 

> ### :bulb: **TIP:**
> *Before restoring the `master` database, note that you CAN restore a COPY of the `master` database from backup by restoring it as, say, `master_test` or something similar. This can be a convenient way of determining exactly WHICH backup of the `master` database you want to restore from BEFORE dropping the server into single-user mode. (Be aware, however, that because of the SPECIAL nature of the master database, DBCC CHECKs against a restored COPY of the `master` db will throw errors BY DESIGN. Or, in other words, don't 'check' to see if your backup of the `master` database might have corruption by restoring a COPY - that copy will always report consitency errors.)*

For instructions on how to restore the `master` database, consult [Microsoft's official documentation on the subject](https://docs.microsoft.com/en-us/sql/relational-databases/backup-restore/restore-the-master-database-transact-sql?view=sql-server-ver15). 

> ### :bulb: **TIP:**
> *To avoid some of the tedium/hassle of sorting out how to start your SQL Server intance in Single User Mode, use [S4's Emergency-Start SQL Server PowerShell Script](/documentation/tools/emergency-start-sql.md) - which helps automate this process to make it MUCH simpler and SIGNIFICANTLY less time-consuming (even if you're not familiar with or 'good at' PowerShell).*

**Restoring the `msdb` Database**
The `msdb` database is leveraged heavily by the SQL Server Agent. As with all databases that you wish to execute 'restore-in-place' operations (i.e., 'restore over the top of' an existing database), the `msdb` database must be into `SINGLE_USER` mode in order to remove any existing connections as part of the `REPLACE` operation when executing a `RESTORE`. 

In cases where putting the `msdb` into `SINGLE_USER` mode is problematic (i.e., you keep getting errors about exclusive access when trying to restore), STOPPING the SQL Server Agent Service on the server will TYPICALLY help remedy this specific issue. 

[TODO: document rebuilding msdb database via installer: https://docs.microsoft.com/en-us/sql/relational-databases/databases/rebuild-system-databases?view=sql-server-ver15 ]

**Restoring the `model` Database**
In most cases, executing a `RESTORE` against the `model` database is typically not a problem. 

However, if the `model` database has been corrupted, is 'missing', or otherwise won't 'work' it will prevent SQL Server from starting - because the `model` database is used as the template database required for the creation of the `tempdb` - each time SQL Server starts. (In other words: no `model` database means no `tempdb` database - which causes SQL Server to crash/shut-down after attempting initial startup procedures.)

To address the scenario of a crashed SQL Server due to problems with the `model` database: 

A. Determine IF and how you want to create backups of your `master` and `msdb` databases - to account for any changes made to either of these databases since your last, regularly scheduled, FULL backups of these databases (e.g., if you're executing FULL backups of the `msdb` database nightly and run into this particular problem at 3PM the next day, you can/will lose ALL job history/etc. unless you make some provisions for a backup). If you need a backup of one or more of these databases, there are two primary ways to achieve them: 

- Since SQL Server is crashed and won't start - you can simply copy the `.mdf` and `.ldf` files for one or both databases into a 'backup' folder on, say, the desktop or some other folder on the server as a set of 'copy' backups. 

- Or, you can start SQL Server in minimal-configuration mode (using [S4's Emergency-Start SQL Server PowerShell Script](/documentation/tools/emergency-start-sql.md)) and manually kick-off FULL backups of one or both databases as needed. 

Executing `FULL` backups is the safest/best approach - but will take more time to the point where simple file-copies of your db/log files is usually a 'good enough' solution in most cases. Likewise, if you're sure you don't care about job history and/or any new logins, server-level objects or CHANGES to server-level objects/details (logins), then you can simply skip step A. 

B. To recover the `model` database, you'll need to rebuild SQL Server's System databases using the steps outlined in [Microsoft's Documentation](https://docs.microsoft.com/en-us/sql/relational-databases/databases/rebuild-system-databases?view=sql-server-ver15). (In essence, this process is fairly similar to running a 'Repair' operation via the SQL Server Installer. NOTE that you will NOT need the SQL Server installation media/DVD to run this repair operation - but you WILL need to locate your 'bootstrap' (installation center) directory on the server - which is typically located at `C:\Program Files\Microsoft SQL Server\130\Setup Bootstrap\SQLServer<current_version>` as part of this process.

> ### :zap: **WARNING:** 
> *ANOTHER option - other than REBUILDING the System Databases via the installer is to locate another server of the same major (and ideally, minor) version as your SQL Server and grab it's model.mdf/.ldf files and simply 'drop' them in over the top of your corrupt/busted `.mdf`/`.ldf` files on your busted SQL Server.*   

> *To use this technique, you'll need to a) remember that IF this allows you get your busted SQL Server to start up, you're NOT done and will need to RESTORE the most recent FULL backup of your model database - to make sure it has been reverted to the exact version as the rest of the databases on your server and b) you will have to STOP the SQL Server services on the 'source' server you're getting these files from - because otherwise the `model` `.mdf`/`.ldf` files will be locked.* 

C. If you had to run a rebuild of the System Databases on your server and either preserved copies off the .mdf/.ldf files for the master and/or msdb databases (to preserve or retain any changesin your environment) or created new, FULL, backups of one or both of these databases, you'll need to 'recover' data from those backup/pseudo-backup processes. 

> ### :bulb: **TIP:**
> *IF you were able to 'borrow'/copy a model database from another server and get your server to restart using this approach/technique, the good news is that not only did you save time by avoiding the 'rebuild' process - but your master and msdb databases should be up-to-date as-is and you should NOT need to restore/recover them and can skip step C.* 

If you created 'backups' by means of copying .mdf/.ldf files to another directory, you can 'recover' by ensuring that SQL Server is stopped, and then copying your 'backup copy' .mdf/.ldf files over the top of the newly rebuilt .mdf/.ldf files created by the rebuild process. (Or, in other words, if you had to run the Rebuild of System Databases processes documented by Microsoft via the 'installer', you've reset your master and mdsb databases back to 'scratch' and lost all logins, configuration, jobs, and other KEY data. To 'recover' that data, you simply need to 'replace' the master and msdb data and log files with the 'good' files that were on your system BEFORE the model database ran into problems.)

> ### :bulb: **TIP:**
> *Whether you're using a copy-paste 'good-enough' backup approach or created FULL backups of master and/or model, it's worthwhile to create ADDITIONAL 'good enough' file-copy backups of the .mdf and .ldf files for the master, model, AND msdb databases after your rebuild and BEFORE you overwrite any of these files via 'good enough' restores or actual T-SQL RESTORE commands. (If you've incurred the time/effort to reset these databases to scratch to work around problems with the model database, it'd suck to overwrite these files only to find that the model database wasn't the only database with problems and that you NOW need new master and/or msdb databases - once your server has cleared the 'hurdle' of getting the tempdb going. In short: it'll only take a few seconds to copy/paste copies of these newly rebuilt data and log files to a safe location - which can come in handy if the universe is trying to serve up a REALLY BAD day to keep you on your toes.)*

Otherwise, if you create FULL backups of the master and/or model database by putting your SQL Server into minimal configuration mode, you'll need to put your SQL Server back into minimal configuration mode to run a RESTORE of the master database. (Technically, you can restore the msdb in SQL Server once it starts normally - so if that's all you backed-up, you can restore it once the server starts normally. Otherwise, if you're restoring the master database and also created a backup of the model database, restore both of them by starting the SQL Server in single-user mode.)

Finally, after you've 'recovered' your FULL or 'good enough' backups of the master/model databases, you should be able to restart your SQL Server Service as normal. 

D. Once SQL Server starts normally, restore/replace the model database from your last FULL backup of the model database. (This'll ensure that it's brought up to the correct version and will ensure it is put back into the exact state or configuration it was in before it was lost/corrupted/destroyed.)

E. Once you're confident that SQL Server is running normally and safely again, clean up any manual FULL backups and/or 'good enough' copies of .mdf/.ldf files you have laying around (or copy them to a safe, off-box, location and nuke/delete them in a day or three - but get them out of production to prevent them from becoming 'turd' files and/or causing any kind of confusion should you be unlucky enough to run into any other similar types of disaster in the future).

F. Kick off brand new, FULL, backups of ALL system databases. Likewise, unless you have truly MASIVE databases, kick of a new DIFF or FULL backup of any critical user databases.

#### Restoring and Recovering User Databases 
Backups of User databases can be used in three primary use-cases or scenarios to recover from disasters: 
- **Latest State Restores.** Used to either create COPIES of a production database (side-by-side configuration if restored on the same-server/host - or simple 'copy' configuration if you restor to an entirely different server/instance) OR to execute REPLACE restores - where you replace a database with a backup of itself. 
- **Point-In-Time Restores.** Similar to the above, except rather than restoring to the latest possible state possible, you're restoring and recovering to a 'last-known-good' state at a previous point in time. 
- **Page-Level Restores.** Unlike either of the scenarios above, this use of backups instructs SQL Server to explicitly execute restore operations against specific database pages ONLY (instead of telling it to restore ALL pages) - and is used solely to address scenarios stemming from physical database corruption.

All THREE of the scenarios above require a FULL backup (and can be 'bolstered' by an OPTIONAL DIFF backup) and an UNBROKEN chain of T-LOG backups from the last FULL (or DIFF) backup up to the point in time where recovery needs to be executed (i.e., up until 'now' for Page-Level and Latest-State restores - and up to the 'last-known-good' time-frame for point-in-time restores). 

> ### :label: **NOTE:** 
> *Step by Step instructions for [Point-In-Time Restores](#point-in-time-recovery-of-user-databases) and [Page-Level Restores](page-level-recovery-of-user-databases) are covered in their own, respective, sections below.* 

**Executing Latest-State Restores**  
A. To restore to the latest state possible, you'll need to execute a tail-of-the-log backup - to ensure that you capture any/all transactions currently stored in the active portion of the log (i.e., the portion that hasn't, yet, been backed up). Optionally, if you only need to restore to a point in time CLOSE to 'now' (i.e., to the point in time where your last, regularly scheduled, T-LOG backup was created) you can skip this step - otherwise, [Create a Non-Destructive Tail-Of-Log Backup](#non-destructive-tail-of-logbackups) before proceeding. 

B. Determine whether you're executing a side-by-side restore or executing a REPLACE restore (i.e., where you're overwriting the existing database from backups). 

C. Determine where your backups are (if they're in a non-default location) and where you'd like to RESTORE your target database (if you're restoring to a non-default) location. 

D. With the info above, wire-up execution of `dbo.restore_databases` to meet your needs. 

For example, if you need to restore a copy of the `widgets` database in a side-by-side configration - with your backup files stored in the default location specified on your SQL Server instance and with the .mdf and .ldf of this database going to the default locations for data and log files, you'd run something similar to the following: 

```sql

EXEC [admindb].dbo.[restore_databases]
	@DatabasesToRestore = N'widgets',
	@RestoredDbNamePattern = N'widgets_restored',
	@SkipLogBackups = 0,
	@ExecuteRecovery = 1,
	@CheckConsistency = 0,
	@DropDatabasesAfterRestore = 0,
	@PrintOnly = 0;
	

```

On the other hand, if you want to specify the root folder where backups for your database are located (i.e., a non-standard location) and if you wanted to push the data/log files to specific directories (i.e., maybe you don't have enough disk space in your main/default area and are pushing this backup as a side-by-side restore to a new/bigger volume), then you'd run something similar to the following: 

```sql

EXEC [admindb].dbo.[restore_databases]
	@DatabasesToRestore = N'widgets',
	@BackupsRootPath = N'N:\SQLBackups',  -- expects that N:\SQLBackups\widgets folder exists with backups
	@RestoredRootDataPath = N'X:\SecondarySqlData',
	@RestoredRootLogPath = N'Z:\SecondarySqlLogs',
	@RestoredDbNamePattern = N'widgets_restored',
	@SkipLogBackups = 0,
	@ExecuteRecovery = 1,
	@CheckConsistency = 0,
	@DropDatabasesAfterRestore = 0,
	@PrintOnly = 0;

```

Finally, if you're executing a REPLACE (i.e., restore-in-place or overwrite operation), you'll need to explicitly specify REPLACE as the value for @AllowReplace - as follows: 

```sql

EXEC [admindb].dbo.[restore_databases]
	@DatabasesToRestore = N'widgets',
	@BackupsRootPath = N'N:\SQLBackups',  -- expects that N:\SQLBackups\widgets folder exists with backups
	@RestoredRootDataPath = N'X:\SecondarySqlData',
	@RestoredRootLogPath = N'Z:\SecondarySqlLogs',
	@RestoredDbNamePattern = N'widgets',  -- HAS to match existing db-name + requires explicit REPLACE for @AllowReplace
	@AllowReplace = N'REPLACE',  -- use with EXTREME caution - overwrites widgets
	@SkipLogBackups = 0,
	@ExecuteRecovery = 1,
	@CheckConsistency = 0,
	@DropDatabasesAfterRestore = 0,
	@PrintOnly = 0;
	
```

> ### :label: **NOTE:** 
> *In ALL of the examples above, @ExecuteRecovery has been set to a value of 1 - meaning that dbo.restore_databases will apply all backups and then RECOVER the database - or bring it online.*

> ### :bulb: **TIP:**
> *If you're restoring backups from the SAME directory where production T-LOG backups are being created, `dbo.restore_databases` will 'look for' and APPLY any new T-LOGs as part of the `RESTORE` process before executing recovery. For example, say that you're doing a side-by-side restore of the `widgets` database - but that the FULL restore takes 28 minutes, and then application of T-LOG backups from the full until 'now' takes an additionl 18 minutes - at that point IF `dbo.restore_databases` executed `RECOVERY`, your `widgets_restored` database would be roughly 46 minutes 'out of date' or 'behind' the main production database. To address this particular concern, once `dbo.restore_databases` finishes restoring the last T-LOG that it 'found' (roughly 46 minutes ago when it started the restore process and enumerated all potential files that it COULD use), it will 'look for' any new/additional files that have cropped up and attempt to apply those as well - before executing recovery. So, if T-LOG backups are/were taking place every 5 minutes against the `widgets` database, roughly 9 new T-LOG backups would be 'found' at this point, and then applied - bringing the `widgets_restored` database to within 5 minutes of 'real-time' (i.e., however long between T-LOG backups). Further, after restoring these 9x T-Log backups, `dbo.restore_databases` would then 'look again' and keeps 'looking again' until no more T-Log backups are found.* 

For more information and options on how to use dbo.restore_databases, make sure to view: 
- [dbo.restore_databases](/documentation/apis/restore_databases.md)
- [Managing and Automating Regular Restore-Tests with S4](/documentation/best-practices/restores.md)

E. Once you've configured dbo.restore_databases with the necessary directives, execute the stored procedure to kick-off the restore operation as needed. 

> ### :bulb: **TIP:**
> *Once you have kicked off the restore process, you may want to check recent history of the admindb.dbo.restore_log (if you've been executing regularly scheduled/automated restore-tests) to get a sense for how long the RESTORE process for the database you're attempting to restore typically takes - to give yourself a ROUGH idea of how much time to expect.* 

F. Once RESTORE + RECOVERY is complete IF you've executed a REPLACE restore (i.e., overwritten your previous database with backups), you'll want to initiate a new FULL backup of this 'new' database to restart the backup chain to 'reset' against other potential disasters/emergencies. 

#### Point in Time Recovery of User Databases
[ADVANCED documentation required. This requires additional, detailed, instructions and a number of CAVEATS about point-in-time RESTORE operations. Further, `dbo.restore_databases` does not YET support a `STOPAT` `@Directive` - but it will soon. Once that's tackled, documentation will, in turn, be a bit easier to address.]

[CAVEATS: Generally never a GOOD IDEA to do a Point in Time Recovery OVER THE TOP of a production database (you may be able to recover to the point in time against a key table where, say, an UPDATE was run without a WHERE clause - but in overwriting the ENTIRE database 'back' to this 'point in time' you LOSE EVERYTHING else.) As such, typically much better to restore a point-in-time recovery DB 'side by side' with your main production db - i.e., if `Widgets` gets trashed, keep it going (and restrict access if/when possible), then restore `Widgets_PreUpdate` or whatever, as needed.]

[HIGH LEVEL INSTRUCTIONS: 
A. Run through exact same process as outlined for Executing Latest-State Step By Step instructions in [Restoring and Recovering User Databases](#rrestoring-and-recovering-user-database) - only, set @PrintOnly value to `1` instead of `0`. 

B. Additionally, set the `@RestoredDbNamePattern` as well - i.e., `N'Widgets_PreUpdate'` or `N'{0}_PreUpdate` as needed. 

C. DETERMINE WHICH T-LOG backup output by `dbo.restore_databases` 'covers' the point in time you wish to restore to (i.e., if you need to recover to 14:22:23 on such and such date, make sure to find the MOST RECENT T-LOG backup taken IMMEDIATELY after that point in time.)

D. Double-check that you've got the right 'covering' T-LOG backup. (If you go 'too far' or 'pass up' your STOP AT point, you have to restore ALL OVER AGAIN.)

E. Copy + Paste + Tweak the OUTPUT of `dbo.restore_backups` UP to the point of the last T-LOG you've identified (i.e., your 'covering T-LOG') 

F. Modify the RESTORE LOG command for that T-LOG so that it 'changes' from something like the following: 

```sql 

RESTORE LOG [Widgets_PreUpdate] FROM DISK = N'D:\SQLBackups\Widgets\LOG_Widgets_backup_2020_05_01_094000_9550647.trn' WITH NORECOVERY;

```

to adhere to the STOPAT syntax defined below: 

```sql 

RESTORE LOG [Widgets_PreUpdate] FROM DISK = N'D:\SQLBackups\Widgets\LOG_Widgets_backup_2020_05_01_094000_9550647.trn' WITH STOPAT = '2020-09-18 14:23:23.008', NORECOVERY;

```

G. Double-check your 'last-known-good'/point-in-time recovery point + the timing/overlap of the T-LOG you've modified witht he STOPAT directive (if you get this wrong, you'll have to restore everything again from scratch).  

H. Execute the commands you've copy/pasted + tweaked. 

I. Once execution has completed, you'll need to RECOVER the database - as per docs in Section D - i.e., [Executing RECOVERY against a database](#executing-recovery-against-a-database). 

e.g., 

```sql 

RESTORE DATABASE [Widgets_PreUpdate] WITH RECOVERY; 
GO

```
J. At this point, you're effectively 'done' - other than that you now need to treat for 'logical corruption'. 

]

#### Page-Level Recovery of User Databases
[ADVANCED documentation required. i.e., this process is non-trivial and will require explicit details here to fully outline the entire process. Moreover, `dbo.restore_databases` has not YET been tweaked to allow `PAGE` directives - once that's the case, the process will be that much easier to document.]

[UNTIL THEN: 

A. Overall/'Manual' process is outlined here: 
https://www.itprotoday.com/sql-server/sql-server-database-corruption-part-x-page-level-restore-operations

B. That can be bolstered by means of the following process: 
    1. Run `dbo.restore_databases` against the DB with the corruption but, 
    2. Make sure that `@PrintOnly` has been set to a value of `1`. 
    3. Copy + Paste + Tweak the printed OUTPUT of `dbo.restore_databases` to manually 'bind' `PAGE = 'x, y, z'` as needed for recovery. 
    
C. NOTE that on Enterprise Edition this operation can/will be an ONLINE operation, but on Standard Edition, you will HAVE to knock the database into SINGLE_USER mode before being able to do page-level restore operations. 

]

#### Smoke and Rubble Restores
[process/tasks (high-level) for process involved]
[Not really much different than restoring/recovering user-dbs with a couple of exceptions: 
- as with restoring user dbs, start by trying to reclaim as much of the t-log as possible. [TODO: determine if 'hack-attach' operations can 'reclaim' t-log data via backups... don't THINK so but it's been a while and IF there's a chance, that needs to go here as a reference/link for addressing smoke-and-rubble DR...  ]
- the above isn't an exception - it's just important enough to REALLY re-stress. 
- you'll need configuration and logins and a bunch of other stuff. 
- S4 helps with config via dbo.export_server_configuration... 
- S4 helps with logins via dbo.export_server_logins
- it should, eventually, help with email/alerts and even S4 configuration via dbo.export_dbmail_configuration (where ... might be a way to securely hash/export the password (maybe using Posh?) or ... the password would be the only thing NOT 'dumped') and via dbo.export_s4_settings.... 
- eventually, there will also need to be an HA configuration - via dbo.export_ha_configuration as well. 
- and, arguably, s4 should also have something like dbo.export_server_objects that addresses things like endpoints, linked-servers, and a bunch of other stuff. 
- and... there should also be ... dbo.export_audits (or dbo.export_server_audits and dbo.export_db_audits... )
- point being... there's a crap ton of stuff to address ... 

]

### Part D: Common Disaster Response Techniques and Tasks

#### Checking the SQL Server Logs
SQL Server's (Event/Error) Logs can provide critical insight into problems occuring on the server and should typically be reviewed whenever assessing the scope or nature of any disaster scenario. 
There are three primary ways in which review of the SQL Server logs can be accomplished: 
- Via the SSMS GUI - which is the easiest and most straight-forward approach.
- Iteratively - via sp_readerrorlog - an UNDOCUMENTED stored procedure that can be handy if/when working from the DAC or via SqlCmd or other command-line scenarios.
- Manually - by means of opening and parsing the 'text' files used by SQL Server as logs. 

**Accessing SQL Server Logs via SSMS**  
To access SQL Server Error logs via SSMS, expand the Management > SQL Server Logs node as shown below - and then double-click on whichever log file you wish to open or review: 

![](https://assets.overachiever.net/s4/images/disaster_recovery/accessing_sql_logs_via_ssms.gif)

> ### :zap: **WARNING:** 
> *Make sure to configure a regularly scheduled job that recycles the SQL Server Logs - otherwise the number of log entries can become excessively large if your server goes long periods of time between reboots. To enable this best-practices configuration, review and then execute S4's [`dbo.manage_server_history`](/documentation/apis/manage_server_history.md) within your envirment.* 

**Using sp_readerrorlog and xp_errorlog**  
In cases where SSMS is not available or preferred, you can 'query' SQL Server's logs via the undocumented procedures `sp_readerrorlog` and `xp_readerrorlog`. 

For information on how to use these stored procedures for 'query' access of the error logs: 
- See [Reading the SQL Server log files using T-SQL](https://www.mssqltips.com/sqlservertip/1476/reading-the-sql-server-log-files-using-tsql/) on mssqltips.com for basic insights into the syntax/etc. 

**Accessing the SQL Server Logs Manually**  
Finally, in the case of really ugly disasters or problems - where your SQL Server can't or won't start, you can access raw log data by opening the text files used by the SQL Server Engine as its log files. 

To access these files:   
1. Review SQL Server's startup parameters - and find the startup value/parameter for the -e switch - as this is the path where SQL Server will keep its error logs.

2. Navigate to the path obtained above (i.e., whatever was specified as the -e switch), where you'll find a number of different plain-text and other files. 

3. SQL Server Error/Event logs are named `ERRORLOG[.#]` - where the CURRENT error log in use by the server does NOT have a .# trailing the name and where `ERRORLOG` files with numbers attached to the file-name are progressive older log files. (Each time SQL Server restarts and/or whenever the error logs are explicitly recycled, SQL Server throws a +1 to the name of each existing log file, creates a new `ERRORLOG` (without a nubmer) as the current log file, and discards any files with a # > than the retention value specified on the server.)

4. You can crack these files open in any application that can read plain text (NotePad, etc.).

#### Connecting to Databases via the DAC  
As per [Microsoft's Documentation for the Dedicated Administrator Connection (DAC)](https://docs.microsoft.com/en-us/sql/database-engine/configure-windows/diagnostic-connection-for-database-administrators?view=sql-server-ver15), the DAC exists to provide SQL Server Administrators with a special diagnostic connection for troubleshooting - primarily for scenarios where normal SQL Server schedulers are thread-starved and/or overloaded. 

**Access to the DAC should be enabled BEFORE Emergencies**  
By default, access to the DAC is only allowed from clients connecting from the host running SQL Server - but this default can (and in most cases should) be modified to allow remote connections (before a disaster strikes) as per [Enabling the DAC](#enabling-the-dac) recommendations provided in [Section 3: Disaster Preparation](#section-3-disaster-preparation) of this document.

**Restrictions when Working with the DAC**
Please note that there are a number of restrictions when working with the DAC (which is designed primarily for DIAGNOSTIC access) - as per [Microsoft's Official Documentation](https://docs.microsoft.com/en-us/sql/database-engine/configure-windows/diagnostic-connection-for-database-administrators?view=sql-server-ver15#restrictions).

**Connecting to the DAC via SSMS**  
Because SSMS, by default, makes a number of different connections into a target server (object explorer, etc.) and due to the fact that the DAC is a single-user-only connection, you can't connect to the DAC via SSMS as you would a 'normal' server. Instead, to connect to the DAC from SSMS, you must do the following: 

1. Open a new Query Window in SSMS (this can be connected to any OTHER server or explicitly disconnected). 

2. Once the new query window has loaded, right-click anywhere in the window itself and select the Connection > Change Connection menu option. 

3. From here specify the 'admin' protocol/specifier along with your server name - e.g., instead of connecting to `MyServer`, specify `admin:MyServer` - along with access credentials. 

4. As you connect, you will likely see an 'error' pop up in SSMS informing you that a connection failed - this is/was likely 'background' and other connections that SSMS NORMALLY runs or attempts to run and NOT the window you explicitly connnected. 

5. To confirm that you are connected to the DAC, you can run the following query: 

<div style="margin-left: 40px;">

```sql 

IF EXISTS(SELECT NULL FROM sys.dm_exec_sessions WHERE endpoint_id = 1 AND session_id = @@SPID) 
	PRINT 'Connected to DAC';
	
```

</div>

**Connecting to the DAC via SqlCmd**
To connect to the DAC via SqlCmd, simply specify the admin signifier/protocol when specifying a new connection. For example: 

```dos

> sqlcmd -S admin:MyServerName

```

#### Addressing Problems with Low Disk Space 
*[DOCUMENTATION PENDING.]*

#### Addressing Problems with 'Full' Database Files
*[DOCUMENTATION PENDING.]*

#### Checking Databases for Corruption
Checking for corruption is a size-of-data operation (the larger your databases, the more time this will take). 

1. To check for corruption you CAN review the SQL Server logs as one means of potentially finding problems or issues – especially if they relate to databases being marked as suspect when starting up a SQL Server instance. 
2. To check the SQL Server Logs, simply open up SQL Server Management Studio, connect to the target server, and then expand the Management node, and expand the SQL Server Logs node, and double-click on the most recent log entry (or any other that might make sense to scan) as per the following screenshot:

3. Note too that you can filter entries by specific keywords, such as database name:
 
4. When dealing with suspect databases, make sure to check events around/during the times when SQL Server is starting up and look for specific reasons or details as to why a database might be marked as suspect. (Many times you’ll see references to paths that are unavailable or will spot information about data potentially being corrupt or ‘suspect’.)
5. Otherwise, to address issues or potential concerns where databases might be experiencing problems due to corruption, you’ll have to perform a check – where the exact syntax you’ll want to use is: 

```sql 

DBCC CHECKDB(dbNameHere) WITH NO_INFOMSGS, ALL_ERRORMSGS;
GO

```

(And, of course, make sure to change the name of your database in the sample above.)

6. And, note, that you’ll want to wait until that ENTIRE check is completed before making decisions about how to proceed. 

7. As such, make sure to use the documentation provided here as a guide for how to respond to corruption. 

#### Non-Destructive Tail-Of-Log Backups
Because the Transaction Log (for `full` and `bulk-logged` RECOVERY databases) contains a change-by-change record of ALL modifications made to a given database, a key component of addressing many disaster recovery scenarios is to ensure that any/all transactions within the 'tail-end-of-the-log' (i.e., the currently active portion of the T-LOG - which hasn't been backed-up yet) gets backed up so that IF something unexpected happens along the way, you don't lose any transactions executed within the last N minutes on the server that have not yet (or would not otherwise have been) been backed up. 

Or, stated more simply, before you 'do anything' to respond to a database-level disaster, it usually makes sense to 'kick off' a Transaction Log backup to ensure that ALL transactional changes that you can possibly capture or back-up have been safely copied to a .trn file. 

That said, in order to recover from a SMALL number of database-specific disasters, it can also make sense to NOT 'truncate' (or risk truncating) the active portion of the log - meaning that you need to run a non-destructive backup of the T-LOG. 

And, because a non-destructive backup of the log will fully preserve any transactional details that need to be captured - without running ANY sort of risk of damaging more advanced options for recovery, the best practice is to grab a 'non-destructive 'tail-of-the-log' backup as an additional contingency-plan/protection before making any potentially destructive changes. 

Finally, in MOST cases when creating a non-destructive tail-of-the-log backup, it will make sense to 'kick' all users/applications out of the database BEFORE initiating this backup. 

To forcibly remove all users from a given database, run the following: 

```sql

ALTER DATABASE [<dbNameHere>] SET SINGLE_USER 
    WITH ROLLBACK IMMEDIATE;
GO

```

*[TODO: document caveats and troubleshooting tips for putting DBs into `SINGLE_USER` mode (i.e., how to not 'hose yourself' by 'losing' this connection, how to 'fight it back' from other processes, etc. + document S4's upcoming sproc `dbo.liberate_database` which more aggressively evicts users/connections from a db + document how to get the db back into `MULTI_USER` mode and so on.]*

**Creating a Non-Destructive Backup of the Transaction Log**  
To create a non-destructive tail-of-the-log backup: 

1. [Wire up dbo.backup_databases against the database in question - with @PrintOnly set to 1 - then execute, the path specified if/as needed, and the `@BackupType` set to `N'LOG'`]. 

<div style="margin-left: 40px;">

```sql 

[example execution of dbo.backup_databases here];

```

</div>

2. [COPY/PASTE output to a new window, and add in WITH NO_TRUNCATE. May also want to modify the file-name accordingly ]  

<div style="margin-left: 40px;">

```sql 

[example output here - modified with the NO_TRUNCATE directive and with _notruncate.trn as part of the file-name]

``` 

</div>

3. Execute command and verify that the .trn file was created. 

*[NOTE: a future (soon-ish) version of `dbo.backup_databases` will allow the `NO_TRUNCATE` @Directive (only if/when @BackupType = 'LOG' - otherwise, already done in the form of COPY_ONLY] - which will make the above just a wee bit easier to tackle. ]*

#### Putting Databases into EMERGENCY Mode
> ### :zap: **WARNING:** 
> *Setting a database into `EMERGENCY` mode should ONLY be done as a last-ditch effort to recover data.* 

> ### :zap: **WARNING:** 
> *Databases in `EMERGENCY` mode are, by definition, going to be in a non-consistent state (i.e., you’ll be looking at the database with some parts of transactions partially implemented and/or rolled back – so your data will be full-on ‘dirty’).*

To set a database into `EMERGENCY` mode, execute the following: 

```sql 

USE master;
GO

ALTER DATABASE [db_name_here] SET EMERGENCY WITH ROLLBACK AFTER 10 SECONDS;
GO

```

For additional information on `EMERGENCY` mode, see [Paul Randal’s blog post detailing samples/examples of how to force a database into RECOVERY_PENDING and how to use EMERGENCY mode](https://www.sqlskills.com/blogs/paul/checkdb-from-every-angle-emergency-mode-repair-the-very-very-last-resort/). 

#### Executing RECOVERY against a Database
[Effectively, just `RESTORE` ... but without specifying media - i.e., if you've run `dbo.restore_databases` and either didn't get to the point where it executes `RECOVERY`, or you explicitly didn't execute `RECOVERY` from `dbo.restore_databases` or `dbo.apply_logs`, etc. ... then you'll have a database in `RESTORING` state... and befor you can bring it online, you'll need to `RECOVER` the database - via the syntax listed below: 

```sql 

RESTORE DATABASE [myDatabaseName_Here] WITH RECOVERY; 
GO

``` 

IN SOME cases, this process can take a few minutes - but, it usually executes quickly. Once it completes, your database is online and will be ready for use (assuming it's been put into `MULTI_USER`, etc.). ]

[Return to Table of Contents](#table-of-contents)

## Section 8: Regular Testing
While the documentation sections above include step-by-step guidelines and other background for addressing particular disaster scenarios, this documentation will still be hard to follow in an actual disaster scenario – without regular practice and testing. Likewise, the above documentation also assumes that all backups are working correctly and as expected. 

But without regular testing to ensure that backups are working (as expected) there’s no guarantee that they’ll be viable when needed to respond to a disaster as subtle changes in network configuration, permissions, patches to the OS or SQL Server, or any other host of small/minor changes might invalidate the backups and make them non-viable. 

### Benefits of Regular Testing
The importance of regular testing can NOT be stressed enough. 

**Without regular testing:**
- You are waiting until a disaster occurs to work through the actual steps and processes needed to restore and recover databases in production. Learning how to address these steps and procedures with the added stress of 'being down' is patently the wrong time to learn how to restore backups and recover databases. 

- You aren’t verifying backup viability and have no idea if your backups will even work when needed. 

**Whereas, WHEN you regularly tests backups and run through regular disaster recovery tests and drills:**
- You are gaining increased comfort, familiarity, and proficiency with the steps AND concepts needed to recover databases. 

- You’re also able to gain a very real sense of how long certain types of recovery operations take. (Essential in meeting SLAs associated with Recovery Time Objectives.)

- You can also test/verify that RPOs are also within scope/SLA by testing the amount of data loss per each recovery test/operation. 

- You’re also helping to ensure that some system-level change or environmental modification hasn’t rendered your backups invalid. 

- You’re also able to check/validate that applications can connect to ‘luke warm’ standby servers or any other servers you might be testing/validating for ‘smoke and rubble’ contingency plans (i.e., disaster recovery scenarios where you’re testing the potential loss of an entire data center).

- Making sure that if there are ANY changes that need to be made to your documentation, that they’re made during REGULAR checks – instead of having to deal with them as ‘variables’ during an actual disaster recovery operation.

### Disaster Recovery Testing

#### Automated DR Testing
*[DOCUMENTATION PENDING.]*
[impossible to dr test everything, but... 2 main ways that S4 can help with testing: 

- in-place/on-box/side-by-side backup validations... 
- warm-backup/secondary backup validations

both should be regularly scheduled and executed nightly... ]

#### Simulated DR Tests 
*[DOCUMENTATION PENDING.]*
[
- Basic RPO and RTO tests... (restore all... did we meet needs? S4 makes this easy... )
]

> ### :bulb: **TIP:**
> *Try to VARY the time of day that you run restore tests. This’ll help you better gauge real recovery times. (i.e., if you are running FULL backups nightly and T-Log backups every 20 minutes, and always test your backups around, say, 10:30AM you can easily end up thinking that recovery only takes, say, 30 minutes – whereas it MIGHT take closer to 1 hour if you were to test closer to 5PM because there are simply MORE transactions to iterate over.)*

[
- corruption - physical and logical (hard to test for the actual, pain-in-the-butt, components - but can regularly and easily test to points in time and/or to verify that you have an unbroken backup chain.)
- point in time
- hardware disasters - (spin up to new hardware with logs or not ... see how much data was lost, how long process took. S4, again, makes this easy... )
- smoke and rubble - certs, logins, data, config.... S4 helps with xyz... 

]

### Addressing Testing Outcomes
*[DOCUMENTATION PENDING.]*

[Return to Table of Contents](#table-of-contents)

## Section 9: Maintenance and Upkeep Concerns
[Documentation needs to address 2 main concerns: 
1. patching/updates - i.e. 'maintenance' - either via Windows/SQL Server patches and/or via application changes/updates etc... 

2. How to account for these changes and/or potential changes in terms of DR. ]

[Return to Table of Contents](#table-of-contents)

## Section 10: Appendices 

### Appendix A: Glossary of Concepts and Terms
*[DOCUMENTATION PENDING.]*

[Return to Table of Contents](#table-of-contents)

### Appendix B: Business Continuity Concepts and Metrics
*[DOCUMENTATION PENDING.]*

[Return to Table of Contents](#table-of-contents)

[S4 Docs Home](/readme.md)