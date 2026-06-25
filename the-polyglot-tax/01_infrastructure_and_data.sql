/*===============================================================================
  The Polyglot Tax — Repro Script 1 of 2 : Infrastructure & Data
  -----------------------------------------------------------------------------
  Reproduces ONLY these two blog posts:
    Part 1 : https://devblogs.microsoft.com/azure-sql/the-polyglot-tax/
    Part 2 : https://devblogs.microsoft.com/azure-sql/the-polyglot-tax-part-2/

  NOTE ON PART 1:
    Part 1 ("The Polyglot Tax") is a conceptual article. It contains NO runnable
    SQL — only an architecture discussion and a pseudo-code agent-workflow
    comparison. Every executable T-SQL statement in this series appears in
    Part 2 ("When JSON Met Graph"). This file therefore creates the objects and
    seed data used by the Part 2 demonstrations.

  PREREQUISITES:
    * SQL Server 2025  (or Azure SQL Database / Managed Instance).
      The native JSON data type, CREATE JSON INDEX, JSON_CONTAINS, and the
      JSON_VALUE(... RETURNING <type>) syntax are SQL Server 2025 features.

  WHAT THIS FILE CREATES:
    * Events                  (native JSON type)        + seed data
    * Customers_WithPhones    (native JSON type)        + seed data
    * Person / Account        (graph NODE tables)       + seed data
    * Owns / SentMoney / Knows (graph EDGE tables)      + seed data
    * Transactions            (relational)              + seed data
    + the indexes used by the Part 2 queries

  Run this file FIRST, then run "02_test_queries.sql".
===============================================================================*/

/*-------------------------------------------------------------------------------
  OPTIONAL — dedicated demo database.
  Uncomment on SQL Server / Managed Instance. (On Azure SQL Database just connect
  directly to your target database; CREATE DATABASE / USE behave differently.)
---------------------------------------------------------------------------------
IF DB_ID('PolyglotTax') IS NULL
    CREATE DATABASE PolyglotTax;
GO
USE PolyglotTax;
GO
-------------------------------------------------------------------------------*/

/*-------------------------------------------------------------------------------
  Clean up for an idempotent re-run. Drop edge tables before node tables.
-------------------------------------------------------------------------------*/
DROP TABLE IF EXISTS Knows;
DROP TABLE IF EXISTS SentMoney;
DROP TABLE IF EXISTS Owns;
DROP TABLE IF EXISTS Person;
DROP TABLE IF EXISTS Account;
DROP TABLE IF EXISTS Events;
DROP TABLE IF EXISTS Customers_WithPhones;
DROP TABLE IF EXISTS Transactions;
GO

/*===============================================================================
  PART 2 — "Why Not Just NVARCHAR(MAX)?"  : the native JSON type
  -----------------------------------------------------------------------------
  Native JSON = pre-parsed binary storage, validated on INSERT. Path lookups
  become offset calculations instead of full string parses.
===============================================================================*/
CREATE TABLE Events (
    EventID   INT IDENTITY PRIMARY KEY,
    PersonID  INT NULL,              -- links to Person (used by the combined query)
    Data      JSON NOT NULL,         -- pre-parsed binary storage, validated on insert
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

-- Seed device-fingerprint documents (used by the window-function & OPENJSON queries)
INSERT INTO Events (PersonID, Data) VALUES
(1, '{"deviceId":"d1","fingerprint":{"browser":"Chrome","os":"Windows","plugins":["AdBlock","LastPass"]}}'),
(2, '{"deviceId":"d2","fingerprint":{"browser":"Firefox","os":"macOS","plugins":["uBlock","Grammarly","DarkReader"]}}'),
(3, '{"deviceId":"d3","fingerprint":{"browser":"Chrome","os":"Linux","plugins":["AdBlock"]}}');
GO

/*===============================================================================
  PART 2 — "JSON Indexes: Teaching the Optimizer About Paths"
===============================================================================*/

/*-- LEGACY approach (SQL Server 2022 and earlier) — shown for contrast. Left
   -- commented so it does not influence the SQL Server 2025 JSON-index plans.
ALTER TABLE Events
    ADD BrowserComputed AS JSON_VALUE(Data, '$.fingerprint.browser') PERSISTED;
GO
CREATE INDEX IX_Events_Browser ON Events(BrowserComputed);
GO
*/

-- SQL Server 2025: omitting FOR (...) defaults to '$' and indexes every
-- key/value in the document recursively.
CREATE JSON INDEX IX_EventData
    ON Events(Data);
GO

/*-- ALTERNATIVE scoped index. Do NOT create alongside IX_EventData (one JSON
   -- index per column; indexed paths cannot overlap). Indexes only the
   -- fingerprint subtree plus deviceId.
CREATE JSON INDEX IX_EventData_Scoped
    ON Events(Data)
    FOR ('$.fingerprint', '$.deviceId');
GO
*/

/*===============================================================================
  PART 2 — JSON index variant for array containment (OPTIMIZE_FOR_ARRAY_SEARCH)
===============================================================================*/
CREATE TABLE Customers_WithPhones (
    CustomerID   INT IDENTITY PRIMARY KEY,
    CustomerInfo JSON NOT NULL
);
GO

CREATE JSON INDEX IX_CustomerJson
    ON Customers_WithPhones (CustomerInfo)
    WITH (OPTIMIZE_FOR_ARRAY_SEARCH = ON);
GO

-- Seed data so the JSON_CONTAINS demo returns a row. (The post shows the query
-- but not its data; this is the minimum needed to reproduce the result.)
INSERT INTO Customers_WithPhones (CustomerInfo) VALUES
(N'{"name":"Jane Doe","phone":["123-456-7890","555-0100"]}'),
(N'{"name":"John Smith","phone":["555-0199"]}');
GO

/*===============================================================================
  PART 2 — "Graph Tables: The MATCH Syntax"  : node & edge tables
  -----------------------------------------------------------------------------
  Node tables carry a system $node_id; edge tables carry $from_id / $to_id.
  Underneath they are ordinary tables (same pages, same transaction log).
===============================================================================*/
CREATE TABLE Person (
    PersonID  INT PRIMARY KEY,
    Name      NVARCHAR(100),
    RiskScore FLOAT
) AS NODE;
GO

CREATE TABLE Account (
    AccountID INT PRIMARY KEY,
    Bank      NVARCHAR(50)
) AS NODE;
GO

CREATE TABLE Owns      AS EDGE;   -- Person  -> Account
CREATE TABLE SentMoney AS EDGE;   -- Account -> Account
CREATE TABLE Knows     AS EDGE;   -- Person  -> Person
GO

-- People
INSERT INTO Person (PersonID, Name, RiskScore) VALUES
(1, 'Alice',  0.3),
(2, 'Bob',    0.6),
(3, 'Carlos', 0.9),
(4, 'Diana',  0.85);
GO

-- Accounts
INSERT INTO Account (AccountID, Bank) VALUES
(101, 'Contoso Bank'),
(102, 'Fabrikam Bank'),
(103, 'Contoso Bank'),
(104, 'Northwind Bank');
GO

-- Ownership edges: Person -> Account
INSERT INTO Owns ($from_id, $to_id)
    SELECT p.$node_id, a.$node_id
    FROM Person p, Account a
    WHERE (p.PersonID = 1 AND a.AccountID = 101)
       OR (p.PersonID = 2 AND a.AccountID = 102)
       OR (p.PersonID = 3 AND a.AccountID = 103)
       OR (p.PersonID = 4 AND a.AccountID = 104);
GO

-- Money-transfer edges: Account -> Account
INSERT INTO SentMoney ($from_id, $to_id)
    SELECT a1.$node_id, a2.$node_id
    FROM Account a1, Account a2
    WHERE (a1.AccountID = 101 AND a2.AccountID = 102)
       OR (a1.AccountID = 102 AND a2.AccountID = 103);
GO

-- Social edges: Person -> Person
INSERT INTO Knows ($from_id, $to_id)
    SELECT p1.$node_id, p2.$node_id
    FROM Person p1, Person p2
    WHERE (p1.PersonID = 1 AND p2.PersonID = 2)
       OR (p1.PersonID = 2 AND p2.PersonID = 3)
       OR (p1.PersonID = 2 AND p2.PersonID = 4)
       OR (p1.PersonID = 3 AND p2.PersonID = 4);
GO

/*===============================================================================
  PART 2 — "The Combined Query" support : relational Transactions table
===============================================================================*/
CREATE TABLE Transactions (
    TxnID     INT IDENTITY PRIMARY KEY,
    PersonID  INT NOT NULL,
    Amount    DECIMAL(12,2),
    Timestamp DATETIME2 DEFAULT SYSUTCDATETIME()
);
GO

CREATE INDEX IX_Txn_Person_Time
    ON Transactions(PersonID, Timestamp) INCLUDE(Amount);
GO

INSERT INTO Transactions (PersonID, Amount, Timestamp) VALUES
(2, 1500.00, DATEADD(DAY, -2, GETUTCDATE())),
(2,  750.00, DATEADD(DAY, -5, GETUTCDATE())),
(3, 9200.00, DATEADD(DAY, -1, GETUTCDATE())),
(4, 3100.00, DATEADD(DAY, -3, GETUTCDATE()));
GO
