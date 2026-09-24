using './main.bicep'

param serverNamePrefix = 'microhack-pg'
param administratorLogin = 'pgadmin'
param administratorLoginPassword = readEnvironmentVariable('POSTGRES_ADMIN_PASSWORD')
param performanceApiKey = readEnvironmentVariable('PERFTEST_API_KEY')
param clientIpAddress = '203.0.113.10'
param postgresqlVersion = '16'
param githubRepository = 'martinpolivka/MicroHack-AppInnovation'
