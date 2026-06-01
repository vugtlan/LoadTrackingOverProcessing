"""
Data Loading Script

Load processed data to target destination using Snowflake with Azure AD OAuth authentication.
"""

import argparse
import logging
from pathlib import Path
import pandas as pd
import snowflake.connector
from azure.identity import DefaultAzureCredential
import os
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class DataLoader:
    """Handle data loading to various targets"""
    
    def __init__(self, input_dir='data/processed'):
        self.input_dir = Path(input_dir)
        self.snowflake_conn = None
    
    def get_snowflake_connection(self):
        """
        Create and return a Snowflake connection using Azure AD OAuth
        
        Authentication flow:
        - Uses Azure DefaultAzureCredential
        - Local development: Uses 'az login' credentials
        - Production/AKS: Uses workload identity (managed identity)
        
        Returns:
            snowflake.connector.connection: Active Snowflake connection
        """
        logger.info("Establishing Snowflake connection...")
        
        # Get username from environment
        username = os.getenv('SNOWFLAKE_USERNAME')
        if not username:
            raise ValueError("SNOWFLAKE_USERNAME not set in .env file")
        
        # Get account from environment
        account_url = os.getenv('SNOWFLAKE_ACCOUNT')
        if not account_url:
            raise ValueError("SNOWFLAKE_ACCOUNT not set in .env file")
        
        # Extract account identifier from URL
        if 'https://' in account_url:
            account = account_url.replace('https://', '').replace('.snowflakecomputing.com', '')
        else:
            account = account_url
        
        # Get OAuth token using Azure credentials
        logger.info("Acquiring Azure AD OAuth token...")
        
        try:
            # Azure scope for Snowflake
            scope = os.getenv('SNOWFLAKE_SCOPE', f'https://{account}.snowflakecomputing.com/.default')
            
            # Try AzureCliCredential first (for local/notebook development)
            # Then fall back to DefaultAzureCredential (for production/managed identity)
            from azure.identity import AzureCliCredential
            
            try:
                credential = AzureCliCredential()
                token = credential.get_token(scope)
                logger.info("✓ Successfully acquired OAuth token using Azure CLI credentials")
            except Exception as cli_error:
                logger.info(f"Azure CLI credential not available: {cli_error}")
                logger.info("Trying DefaultAzureCredential...")
                credential = DefaultAzureCredential()
                token = credential.get_token(scope)
                logger.info("✓ Successfully acquired OAuth token using DefaultAzureCredential")
            
        except Exception as e:
            logger.error(f"Failed to acquire OAuth token: {e}")
            logger.error("Make sure you're logged in with: az login")
            logger.error("Or ensure managed identity/workload identity is configured")
            raise
        
        # Build connection parameters with OAuth
        connection_params = {
            'user': username,
            'account': account,
            'authenticator': 'oauth',
            'token': token.token,
        }
        
        # Add optional parameters only if they exist and are not placeholder values
        warehouse = os.getenv('SNOWFLAKE_WAREHOUSE')
        if warehouse and warehouse != 'your_warehouse_name':
            connection_params['warehouse'] = warehouse
            logger.info(f"Using warehouse: {warehouse}")
        
        database = os.getenv('SNOWFLAKE_DATABASE')
        if database and database != 'your_database_name':
            connection_params['database'] = database
            logger.info(f"Using database: {database}")
        
        schema = os.getenv('SNOWFLAKE_SCHEMA')
        if schema and schema != 'your_schema_name':
            connection_params['schema'] = schema
            logger.info(f"Using schema: {schema}")
        
        role = os.getenv('SNOWFLAKE_ROLE')
        if role and role != 'your_role_name':
            connection_params['role'] = role
            logger.info(f"Using role: {role}")
        
        logger.info(f"Connecting to Snowflake as {username} on account {account}")
        logger.info(f"Using OAuth authentication with Azure AD")
        
        self.snowflake_conn = snowflake.connector.connect(**connection_params)
        logger.info("✓ Connection established successfully!")
        
        return self.snowflake_conn
    
    def read_sql_file(self, sql_file_path):
        """
        Read SQL query from a file
        
        Args:
            sql_file_path (str): Path to the SQL file
            
        Returns:
            str: SQL query content
        """
        logger.info(f"Reading SQL file: {sql_file_path}")
        
        sql_path = Path(sql_file_path)
        
        if not sql_path.exists():
            raise FileNotFoundError(f"SQL file not found: {sql_file_path}")
        
        with open(sql_path, 'r') as f:
            query = f.read()
        
        logger.info(f"Successfully read SQL file ({len(query)} characters)")
        return query
    
    def execute_snowflake_query(self, query):
        """
        Execute a SQL query on Snowflake
        
        Args:
            query (str): SQL query to execute
            
        Returns:
            pandas.DataFrame: Query results
        """
        logger.info("Executing Snowflake query...")
        
        if not self.snowflake_conn:
            self.get_snowflake_connection()
        
        try:
            # Use pandas to execute query and fetch results
            df = pd.read_sql(query, self.snowflake_conn)
            logger.info(f"Query executed successfully. Retrieved {len(df)} rows, {len(df.columns)} columns")
            
            return df
                
        except Exception as e:
            logger.error(f"Failed to execute query: {e}")
            raise
    
    def close_snowflake_connection(self):
        """Close the Snowflake connection"""
        if self.snowflake_conn:
            self.snowflake_conn.close()
            logger.info("Snowflake connection closed")
            self.snowflake_conn = None
    
    def load_from_snowflake(self, sql_file_path='sql/loadsQuery.sql', params=None):
        """
        Load data from Snowflake using a SQL file
        
        Args:
            sql_file_path (str): Path to SQL file containing the query
            params (dict): Optional dictionary of parameters to substitute in the SQL query
                          Uses Python string formatting with {param_name} placeholders
            
        Returns:
            pandas.DataFrame: Query results
        """
        logger.info(f"Loading data from Snowflake using {sql_file_path}...")
        
        try:
            # Read the SQL query
            query = self.read_sql_file(sql_file_path)
            
            # Substitute parameters if provided
            if params:
                logger.info(f"Substituting parameters: {params}")
                # Use format() with **params to substitute {param_name} placeholders
                # For date strings, we need to quote them
                formatted_params = {}
                for key, value in params.items():
                    # Quote string values for SQL
                    if isinstance(value, str):
                        formatted_params[key] = f"'{value}'"
                    else:
                        formatted_params[key] = value
                query = query.format(**formatted_params)
            
            # Execute the query and get results
            df = self.execute_snowflake_query(query)
            
            logger.info("Data loaded successfully from Snowflake")
            return df
            
        except Exception as e:
            logger.error(f"Failed to load data from Snowflake: {e}")
            raise
        finally:
            self.close_snowflake_connection()
    
    def load_to_staging(self):
        """Load data to staging area"""
        logger.info("Loading data to staging...")
        
        # TODO: Implement staging load logic
        # Example:
        # from sqlalchemy import create_engine
        # engine = create_engine(STAGING_DB_URL)
        # df.to_sql('staging_table', engine, if_exists='replace')
        
        processed_files = list(self.input_dir.glob('*.csv'))
        
        for file in processed_files:
            logger.info(f"Loading {file.name} to staging...")
            df = pd.read_csv(file)
            logger.info(f"Loaded {len(df)} rows from {file.name}")
            
            # Placeholder: In production, load to actual staging database
            logger.info(f"Would load to staging: {file.name}")
        
        logger.info("Staging load complete!")
    
    def load_to_warehouse(self):
        """Load data to data warehouse"""
        logger.info("Loading data to warehouse...")
        
        # TODO: Implement warehouse load logic
        
        logger.info("Warehouse load complete!")
    
    def load_to_feature_store(self):
        """Load features to feature store"""
        logger.info("Loading data to feature store...")
        
        # TODO: Implement feature store load logic
        
        logger.info("Feature store load complete!")


def main():
    parser = argparse.ArgumentParser(description='Load processed data')
    parser.add_argument('--target', type=str, required=True,
                        choices=['staging', 'warehouse', 'feature-store', 'snowflake'],
                        help='Target destination for data')
    parser.add_argument('--input-dir', type=str, default='data/processed',
                        help='Input directory with processed data')
    parser.add_argument('--sql-file', type=str, default='sql/loadsQuery.sql',
                        help='SQL file path for Snowflake queries')
    parser.add_argument('--output-file', type=str, default=None,
                        help='Output file path to save Snowflake query results')
    parser.add_argument('--limit', type=int, default=None,
                        help='Limit number of rows to fetch (for testing)')
    
    args = parser.parse_args()
    
    loader = DataLoader(input_dir=args.input_dir)
    
    if args.target == 'staging':
        loader.load_to_staging()
    elif args.target == 'warehouse':
        loader.load_to_warehouse()
    elif args.target == 'feature-store':
        loader.load_to_feature_store()
    elif args.target == 'snowflake':
        # Load data from Snowflake
        sql_file = args.sql_file
        
        # Apply limit if specified (for testing)
        if args.limit:
            logger.info(f"Applying LIMIT {args.limit} to query")
            query = loader.read_sql_file(sql_file)
            if 'LIMIT' not in query.upper():
                query = f"{query.rstrip(';')} LIMIT {args.limit};"
            df = loader.execute_snowflake_query(query)
            loader.close_snowflake_connection()
        else:
            df = loader.load_from_snowflake(sql_file_path=sql_file)
        
        # Save to file if output path specified
        if args.output_file:
            output_path = Path(args.output_file)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            
            if output_path.suffix == '.csv':
                df.to_csv(output_path, index=False)
            elif output_path.suffix == '.parquet':
                df.to_parquet(output_path, index=False)
            else:
                df.to_csv(output_path, index=False)
            
            logger.info(f"Data saved to {output_path}")
        
        # Display summary
        logger.info(f"\nDataFrame Info:")
        logger.info(f"Shape: {df.shape}")
        logger.info(f"Columns: {list(df.columns)}")
        logger.info(f"\nFirst few rows:")
        print(df.head())


if __name__ == "__main__":
    main()
