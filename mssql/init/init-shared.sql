CREATE DATABASE shared_db;
GO
USE shared_db;
GO
CREATE LOGIN shared_user WITH PASSWORD = 'RootPass123!';
GO
CREATE USER shared_user FOR LOGIN shared_user;
GO
ALTER ROLE db_owner ADD MEMBER shared_user;
GO
