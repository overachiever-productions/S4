# S4 Audit Monitoring 

## Overview 
[provide an overview of their purpose - for ensuring that audits are NOT modified or 'messed with'.]

## WorkFlow

[overview of how to use these scripts.]

- define and tune/tweak audit and specs as needed. (Template is found in the /setup and configuration/ folder... )
- once you've 'stabilized' the audit/specs as desired... generate a signature for the audit using dbo.generate_audit_signature and generate a signature for all associated specifications via dbo.generate_specification_signature... 
- create a job/execution to monitor the audit signature. 
- do the same per each specification you need to monitor. (you can put all operations into the same job - but just note that there are at least 2x different steps to address here (assuming just a single audit with only a single bound/associated specification.)

## Security Warnings

[something to the effect of ... if someone has the perms to MODIFY an AUDIT, they also have the perms to modify a signature/hash - and tweak the jobs that you're running to ensure that something hasn't changed. Or, in other words... these sprocs only work fairly well as a LIGHT-WEIGHT check/deterent. If security is a PRIMARY concern, then you'll want to do the following: 
- potentially set up these jobs (as a honeypot)
- instead, any time you make a change to audits/specs... generate their updated signatures... 
- create a ps or other job that'll connect to the SQL Server at various times, get the hash/signature of the audit + spec(s) you're monitoring, and then check them (outside of sql server). 


```
Powershell EXAMPLE GOES HERE
```
]


## Configuration Example

[assume we're going to set up an audit called 'Server Audit' - and bind it to a 'Server Audit Specification' and, in the case of an Enterprise Edition server, to a 'Jobs Monitoring (msdb)' specification as well. ]

Steps would be: 

1. create/define the audit:

```
create audit sample here
```

2. define a spec 

```
spec example here
```

3. tune / tweak as needed. e.g., if you want to exclude SQLTelemetry you'd do it like so: 

```
exclude sql telemetry example here
```

WARNING: removing actions/activities by an entire login/user obviously runs the risks of adding significant vulnerabilities/blackholes/whatever in your audit.. 

4. Generate Audit and Spec signatures: 

```
DECLARE @auditSignature bigint = 0, @serverSpecSignature bigInt = 0, @msdbSpecSignature bigint = 0;
dbo.generate_audit_signature
    etc... 
    
    
dbo.generate_specificiation_signature
    @Target = N'SERVER'
    etc... 
    
    -- note: make sure to @includeguidInSignature... 
    --       so that ownership (parent) checks are implied/handled automatically.
    
dbo.generate_specification_signature 
    @Target = N'msdb', 
    etc... 

    -- note: make sure to @includeguidInSignature...
    --       so that ownership (parent) checks are implied/handled automatically.
```
    
5. Setup jobs to ensure/validate checks. 

[if you're in a simple environment and don't need ABSOLTUE security... you can use sprocs as follows ]

```
EXEC dbo.verify_audit_configuration 
    @AuditName = ... etc;
    
EXEC dbo.verify_specification_configuration
    @Target = N'SERVER',
    @SpecificationName = etc;
    
EXEC dbo.verify_specification_configuration
    @Target = N'msdb',
    @SpecificationName = etc;
```

[otherwise, if security is bigger deal, you'll need to set up PS jobs and schedule them for regular execution... as per the examples in the Security Warnings Section]