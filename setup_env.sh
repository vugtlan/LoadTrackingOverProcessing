#!/bin/bash

# Setup .env file with user's Snowflake username

echo "Setting up .env file..."

# Check if .env already exists
if [ -f .env ]; then
    read -p ".env file already exists. Overwrite? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Setup cancelled."
        exit 1
    fi
fi

# Prompt for username
read -p "Enter your Snowflake username (without @chrobinson.com): " username

# Copy template and replace username
cp .env.example .env
sed -i "s/your_username@chrobinson.com/${username}@chrobinson.com/" .env

echo "✓ .env file created successfully!"
echo "Your Snowflake username is set to: ${username}@chrobinson.com"
