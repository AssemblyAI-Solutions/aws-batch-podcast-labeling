FROM --platform=linux/amd64 python:3.9-slim

# Install dependencies
RUN pip install --no-cache-dir \
    boto3 \
    assemblyai \
    requests \
    pandas

# Set working directory
WORKDIR /app

# Copy your script
COPY batch_transcribe.py .

# Set environment variables
ENV AWS_DEFAULT_REGION=us-west-2

# Run the script
ENTRYPOINT ["python", "batch_transcribe.py"]