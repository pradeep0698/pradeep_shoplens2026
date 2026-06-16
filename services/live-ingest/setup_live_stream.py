import os
import time
from dotenv import load_dotenv
from google.cloud.video import live_stream_v1
from google.cloud.video.live_stream_v1.services.livestream_service import LivestreamServiceClient
from google.protobuf import duration_pb2

load_dotenv()

PROJECT_ID = os.environ["PROJECT_ID"]
LOCATION = os.environ["LOCATION"]
BUCKET_NAME = os.environ["BUCKET_NAME"]
CHANNEL_ID = os.environ["CHANNEL_ID"]
INPUT_ID = os.environ["INPUT_ID"]


def create_input() -> live_stream_v1.Input:
    client = LivestreamServiceClient()
    parent = f"projects/{PROJECT_ID}/locations/{LOCATION}"

    input_resource = live_stream_v1.Input(
        type_=live_stream_v1.Input.Type.RTMP_PUSH,
    )

    operation = client.create_input(
        parent=parent,
        input=input_resource,
        input_id=INPUT_ID,
    )
    response = operation.result(timeout=300)
    print(f"Created input: {response.name}")
    print(f"RTMP ingest URI: {response.uri}")
    return response


def create_channel(input_name: str) -> live_stream_v1.Channel:
    client = LivestreamServiceClient()
    parent = f"projects/{PROJECT_ID}/locations/{LOCATION}"

    channel = live_stream_v1.Channel(
        input_attachments=[
            live_stream_v1.InputAttachment(
                key="my-input",
                input=input_name,
            )
        ],
        output=live_stream_v1.Channel.Output(
            uri=f"gs://{BUCKET_NAME}/hls-output/",
        ),
        elementary_streams=[
            live_stream_v1.ElementaryStream(
                key="es_video",
                video_stream=live_stream_v1.VideoStream(
                    h264=live_stream_v1.VideoStream.H264CodecSettings(
                        profile="high",
                        bit_rate_bps=3_000_000,
                        frame_rate=30,
                        height_pixels=720,
                        width_pixels=1280,
                    )
                ),
            ),
            live_stream_v1.ElementaryStream(
                key="es_audio",
                audio_stream=live_stream_v1.AudioStream(
                    codec="aac",
                    channel_count=2,
                    bitrate_bps=128_000,
                    sample_rate_hertz=48_000,
                ),
            ),
        ],
        mux_streams=[
            live_stream_v1.MuxStream(
                key="mux_video",
                elementary_streams=["es_video", "es_audio"],
                segment_settings=live_stream_v1.SegmentSettings(
                    segment_duration=duration_pb2.Duration(seconds=6),
                ),
            ),
        ],
        manifests=[
            live_stream_v1.Manifest(
                file_name="manifest.m3u8",
                type_=live_stream_v1.Manifest.ManifestType.HLS,
                mux_streams=["mux_video"],
                max_segment_count=5,
            ),
        ],
    )

    operation = client.create_channel(
        parent=parent,
        channel=channel,
        channel_id=CHANNEL_ID,
    )
    response = operation.result(timeout=300)
    print(f"Created channel: {response.name}")
    playback_url = f"https://storage.googleapis.com/{BUCKET_NAME}/hls-output/manifest.m3u8"
    print(f"HLS playback URL: {playback_url}")
    return response


def start_channel() -> None:
    client = LivestreamServiceClient()
    channel_name = f"projects/{PROJECT_ID}/locations/{LOCATION}/channels/{CHANNEL_ID}"

    operation = client.start_channel(name=channel_name)
    operation.result(timeout=300)
    print(f"Started channel: {channel_name}")


def get_channel_status() -> live_stream_v1.Channel:
    client = LivestreamServiceClient()
    channel_name = f"projects/{PROJECT_ID}/locations/{LOCATION}/channels/{CHANNEL_ID}"

    channel = client.get_channel(name=channel_name)
    print(f"Channel state: {channel.streaming_state.name}")
    return channel


def main():
    input_resource = create_input()
    create_channel(input_name=input_resource.name)

    print("Waiting 10 seconds before starting channel...")
    time.sleep(10)

    start_channel()

    print("Polling channel status...")
    for _ in range(6):
        channel = get_channel_status()
        if channel.streaming_state == live_stream_v1.Channel.StreamingState.STREAMING:
            print("Channel is live and accepting RTMP input.")
            break
        time.sleep(10)


if __name__ == "__main__":
    main()
