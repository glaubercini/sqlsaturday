Resources:
https://github.com/JetterMcTedder/blogFiles/raw/refs/heads/main/AdventureWorksLT2025.bak
https://learn.microsoft.com/en-us/sql/t-sql/statements/create-external-model-transact-sql?view=sql-server-ver17
https://github.com/AzureSQLDB/SQLin5/blob/main/newAIinSQL2025/getting-started-with-ai.md
https://www.youtube.com/@AzureSQL

For SQL Server 2025 you may want to import the .bak
```SQL
RESTORE FILELISTONLY FROM DISK = N'C:\dir_to\AdventureWorksLT2025.bak';
```

It is possible to test if your key, model API, and request are working with PowerShell
```PowerShell
$endpoint = "https://my_model_name.openai.azure.com/openai/deployments/text-embedding-ada-002/embeddings?api-version=2023-05-15"
$apiKey = "MY_API_KEY"

$body = @{
    input = "This is a test sentence for embedding."
} | ConvertTo-Json -Depth 3

$headers = @{
    "api-key" = $apiKey
    "Content-Type" = "application/json"
}

$response = Invoke-RestMethod -Uri $endpoint -Method Post -Headers $headers -Body $body
$response | ConvertTo-Json -Depth 10 | Out-String
```