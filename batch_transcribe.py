import os
import boto3
import assemblyai as aai
import concurrent.futures
from typing import List
import re
import pandas as pd

# Configure AWS and AssemblyAI clients
s3_client = boto3.client('s3')
aai.settings.api_key = os.environ['ASSEMBLYAI_API_KEY']
MAX_CONCURRENT_JOBS = int(os.environ.get('MAX_CONCURRENT_JOBS', '200'))

def transcribe_audio_file(presigned_url: str) -> str:
    # Create transcriber with language detection
    transcriber = aai.Transcriber(config=aai.TranscriptionConfig(language_detection=True, speaker_labels=True))
    
    # Transcribe audio file and poll for completion
    transcript = transcriber.transcribe(presigned_url)
    return transcript

def label_speakers(transcript: aai.Transcript) -> str:
    text_with_speaker_labels = ""

    for utt in transcript.utterances:
        text_with_speaker_labels += f"Speaker {utt.speaker}:\n{utt.text}\n"

    # Count the number of unique speaker labels
    unique_speakers = set(utterance.speaker for utterance in transcript.utterances)

    questions = []
    for speaker in unique_speakers:
        questions.append(
            aai.LemurQuestion(
                question=f"Who is speaker {speaker}?",
            )
        )

    result = aai.Lemur().question(
        questions,
        input_text=text_with_speaker_labels,
        final_model=aai.LemurModel.claude3_5_sonnet,
        context="Your task is to infer the speaker's name from the speaker-labelled transcript"
    )

    speaker_mapping = {}

    for qa_response in result.response:
        pattern = r"Who is speaker (\w)\?"
        match = re.search(pattern, qa_response.question)
        if match and match.group(1) not in speaker_mapping.keys():
            speaker_mapping.update({match.group(1): qa_response.answer})

    speaker_labelled_transcript = ""

    for utterance in transcript.utterances:
        speaker_name = speaker_mapping[utterance.speaker]
        speaker_labelled_transcript += f"{speaker_name}:\n{utterance.text}\n\n"

    return speaker_labelled_transcript

def get_audio_files(bucket_name: str, prefix: str) -> List[dict]:
    """Get list of audio files from CSV in S3 bucket"""
    try:
        # Remove s3:// prefix if present
        bucket_name = bucket_name.replace('s3://', '')
        
        # Get CSV file from S3
        response = s3_client.get_object(
            Bucket=bucket_name,
            Key=f"{prefix}/episodes.csv" if prefix else "episodes.csv"
        )
        
        # Read CSV into pandas DataFrame
        df = pd.read_csv(response['Body'])
        
        # Validate required columns
        required_columns = ['podcast_id', 'episode_id', 'audio_url']
        if not all(col in df.columns for col in required_columns):
            raise ValueError(f"CSV must contain columns: {required_columns}")
        
        # Convert DataFrame to list of dictionaries
        return df.to_dict('records')
    except Exception as e:
        print(f"Error reading CSV: {str(e)}")
        return []

def process_audio_file(bucket_name: str, episode_data: dict) -> None:
    try:
        audio_url = episode_data['audio_url']
        podcast_id = str(episode_data['podcast_id'])
        episode_id = str(episode_data['episode_id'])
        
        transcript = transcribe_audio_file(audio_url)
        speaker_labelled_transcript = label_speakers(transcript)
        
        # Save transcription to S3 with partitioned path as txt file
        output_key = f"podcast_id={podcast_id}/episode_id={episode_id}/{episode_id}_transcript.txt"
        s3_client.put_object(
            Bucket=bucket_name,
            Key=output_key,
            Body=speaker_labelled_transcript
        )
        
        print(f"Successfully transcribed episode {episode_id} to {output_key}")
        return True
        
    except Exception as e:
        print(f"Error processing episode {episode_data.get('episode_id')}: {str(e)}")
        return False

def main():
    # Get environment variables
    bucket_name = os.environ['S3_BUCKET_LOCATION']
    prefix = os.environ.get('S3_BUCKET_PREFIX', '')
    
    # Get list of episodes from CSV
    episodes = get_audio_files(bucket_name, prefix)
    if not episodes:
        print("No episodes found to process")
        return

    print(f"Found {len(episodes)} episodes to process")
    print(f"Processing with max {MAX_CONCURRENT_JOBS} concurrent jobs")
    
    # Process files concurrently
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_CONCURRENT_JOBS) as executor:
        futures = [
            executor.submit(process_audio_file, bucket_name, episode)
            for episode in episodes
        ]
        
        # Wait for all futures to complete
        completed = 0
        for future in concurrent.futures.as_completed(futures):
            completed += 1
            print(f"Progress: {completed}/{len(episodes)} files processed")

if __name__ == "__main__":
    main()
