/*===============================================================================
  The Polyglot Tax — Repro Script 2 of 2 : Test / Demonstration Queries
  -----------------------------------------------------------------------------
  Reproduces the runnable queries from:
    Part 2 : https://devblogs.microsoft.com/azure-sql/the-polyglot-tax-part-2/
  (Part 1 contains no runnable SQL — see the notes in 01_infrastructure_and_data.sql.)

  PREREQUISITES:
    * Run "01_infrastructure_and_data.sql" first.
    * SQL Server 2025 / Azure SQL.

  IMPORTANT — RUN TOP TO BOTTOM:
    Execution order matters. Section 4 ("Schema Evolution") INSERTs two extra
    rows into Events. The window-function and OPENJSON queries are intentionally
    placed BEFORE those inserts so their results match the blog (3 rows). The
    two schema-evolution INSERTs live here (not in the setup script) because
    they are part of that demonstration — each pairs with an OUTPUT/SELECT that
    shows the evolving document shape.
===============================================================================*/

/*-------------------------------------------------------------------------------
  1) OPENJSON & Window Functions — document access + analytics in one plan.
     JSON_VALUE extracts scalars; COUNT(*) OVER (PARTITION BY ...) is the analytic.

  Expected:
     EventID | deviceId | browser | os      | BrowserCount
     1       | d1       | Chrome  | Windows | 2
     3       | d3       | Chrome  | Linux   | 2
     2       | d2       | Firefox | macOS   | 1
-------------------------------------------------------------------------------*/
SELECT
    e.EventID,
    JSON_VALUE(e.Data, '$.deviceId')            AS deviceId,
    JSON_VALUE(e.Data, '$.fingerprint.browser') AS browser,
    JSON_VALUE(e.Data, '$.fingerprint.os')      AS os,
    COUNT(*) OVER (
        PARTITION BY JSON_VALUE(e.Data, '$.fingerprint.browser')
    )                                           AS BrowserCount
FROM Events e;
GO

/*-------------------------------------------------------------------------------
  2) Exploding arrays with OPENJSON — CROSS APPLY over the plugins array,
     JSON_VALUE for the scalar browser, GROUP BY to aggregate.

  Expected:
     browser | PluginName | EventCount
     Chrome  | AdBlock    | 2
     Chrome  | LastPass   | 1
     Firefox | uBlock     | 1
     Firefox | Grammarly  | 1
     Firefox | DarkReader | 1
-------------------------------------------------------------------------------*/
SELECT
    JSON_VALUE(e.Data, '$.fingerprint.browser') AS browser,
    plugin.value                                AS PluginName,
    COUNT(*)                                    AS EventCount
FROM Events e
CROSS APPLY OPENJSON(e.Data, '$.fingerprint.plugins') plugin
GROUP BY JSON_VALUE(e.Data, '$.fingerprint.browser'), plugin.value;
GO

/*-------------------------------------------------------------------------------
  3) Array containment, made index-seekable by OPTIMIZE_FOR_ARRAY_SEARCH.

  Expected: the "Jane Doe" row (its phone array contains 123-456-7890).
-------------------------------------------------------------------------------*/
SELECT * FROM Customers_WithPhones
WHERE JSON_CONTAINS(CustomerInfo, '123-456-7890', '$.phone[*]') = 1;
GO

/*===============================================================================
  4) Schema Evolution Without Downtime
     The two INSERTs below evolve the document shape across "deployments".
     They run AFTER the queries above so those results stay clean (3 rows).
===============================================================================*/

-- Week 1 deployment
INSERT INTO Events (PersonID, Data) VALUES
(NULL, '{"version":1,"action":"click","target":"button"}');
GO

-- Week 2 deployment: added an analytics block.
-- OUTPUT returns the inserted row immediately; JSON_VALUE(... RETURNING INT)
-- types the value inline — no CAST wrapper.
INSERT INTO Events (PersonID, Data)
OUTPUT
    inserted.EventID,
    JSON_VALUE(inserted.Data, '$.version' RETURNING INT) AS Version,
    JSON_VALUE(inserted.Data, '$.action')                AS Action
VALUES
(NULL, '{"version":2,"action":"click","target":"button","analytics":{"duration":1.5}}');
GO

/*  Both document shapes coexist. A missing path returns NULL, not an error.
    Expected:
      Action | Target | Duration
      click  | button | NULL     -- v1 row: path does not exist
      click  | button | 1.5      -- v2 row: path exists, returned as FLOAT      */
SELECT
    JSON_VALUE(Data, '$.action')                             AS Action,
    JSON_VALUE(Data, '$.target')                             AS Target,
    JSON_VALUE(Data, '$.analytics.duration' RETURNING FLOAT) AS Duration
FROM Events
WHERE JSON_VALUE(Data, '$.version') IS NOT NULL;
GO

/*===============================================================================
  5) Graph — the MATCH pattern
===============================================================================*/

/*-------------------------------------------------------------------------------
  5a) People connected through account transfers:
      p1 owns a1, a1 sent money to a2, a2 owned by p2.

  Expected (with the sample data):
     Sender | SenderRisk | FromBank      | ToBank        | Receiver | ReceiverRisk
     Alice  | 0.3        | Contoso Bank  | Fabrikam Bank | Bob      | 0.6
     Bob    | 0.6        | Fabrikam Bank | Contoso Bank  | Carlos   | 0.9
-------------------------------------------------------------------------------*/
SELECT
    p1.Name      AS Sender,
    p1.RiskScore AS SenderRisk,
    a1.Bank      AS FromBank,
    a2.Bank      AS ToBank,
    p2.Name      AS Receiver,
    p2.RiskScore AS ReceiverRisk
FROM
    Person p1, Owns o1, Account a1,
    SentMoney s,
    Account a2, Owns o2, Person p2
WHERE MATCH(p1-(o1)->a1-(s)->a2<-(o2)-p2)
AND p1.PersonID <> p2.PersonID;
GO

/*-------------------------------------------------------------------------------
  5b) People directly connected to high-risk individuals (RiskScore > 0.8).

  Expected (with the sample data):
     Person | RiskScore | KnowsHighRisk | TheirRisk
     Bob    | 0.6       | Carlos        | 0.9
     Bob    | 0.6       | Diana         | 0.85
     Carlos | 0.9       | Diana         | 0.85
-------------------------------------------------------------------------------*/
SELECT
    p1.Name      AS Person,
    p1.RiskScore,
    p2.Name      AS KnowsHighRisk,
    p2.RiskScore AS TheirRisk
FROM Person p1, Knows k, Person p2
WHERE MATCH(p1-(k)->p2)
AND p2.RiskScore > 0.8;
GO

/*===============================================================================
  6) The Combined Query — relational + JSON + graph in ONE execution plan.
     MATCH cannot reference node aliases from an outer JOIN/APPLY, so the graph
     traversal is pre-computed in a CTE that the optimizer inlines.

  Expected:
     Name   | RiskScore | Browser | FraudConnections | WeeklyVolume
     Bob    | 0.6       | Firefox | 2                | 2250.00
     Carlos | 0.9       | Chrome  | 1                | 9200.00
===============================================================================*/
WITH FraudConnections AS (
    SELECT
        p1.PersonID,
        COUNT(*) AS FraudConnectionCount
    FROM Person p1, Knows k, Person suspect
    WHERE MATCH(p1-(k)->suspect)
    AND suspect.RiskScore > 0.8
    GROUP BY p1.PersonID
)
SELECT
    p.Name,
    p.RiskScore,
    -- JSON: browser from the device fingerprint (RETURNING types it inline)
    JSON_VALUE(e.Data, '$.fingerprint.browser' RETURNING NVARCHAR(50)) AS Browser,
    -- Graph: fraud connections (from the CTE)
    ISNULL(fc.FraudConnectionCount, 0) AS FraudConnections,
    -- Relational: recent transaction total
    (
        SELECT SUM(Amount)
        FROM Transactions t
        WHERE t.PersonID = p.PersonID
        AND t.Timestamp > DATEADD(DAY, -7, GETUTCDATE())
    ) AS WeeklyVolume
FROM Person p
JOIN Events e ON p.PersonID = e.PersonID
LEFT JOIN FraudConnections fc ON fc.PersonID = p.PersonID
WHERE p.RiskScore > 0.5
ORDER BY FraudConnections DESC;
GO
