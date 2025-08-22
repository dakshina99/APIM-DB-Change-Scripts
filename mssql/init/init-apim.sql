CREATE DATABASE apim_db;
GO
USE apim_db;
GO
CREATE LOGIN apim_user WITH PASSWORD = 'RootPass123!';
GO
CREATE USER apim_user FOR LOGIN apim_user;
GO
ALTER ROLE db_owner ADD MEMBER apim_user;
GO
