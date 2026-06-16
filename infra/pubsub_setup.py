import os
from dotenv import load_dotenv
from google.cloud import pubsub_v1, storage

load_dotenv()

PROJECT_ID = os.environ["PROJECT_ID"]
TOPIC_ID = os.environ["TOPIC_ID"]
SUBSCRIPTION_ID = os.environ["SUBSCRIPTION_ID"]
BUCKET_NAME = os.environ["BUCKET_NAME"]
PUSH_ENDPOINT = os.environ["PUSH_ENDPOINT"]


def create_topic() -> str:
    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)
    topic = publisher.create_topic(request={"name": topic_path})
    print(f"Created topic: {topic.name}")
    return topic.name


def create_push_subscription(topic_name: str) -> None:
    subscriber = pubsub_v1.SubscriberClient()
    subscription_path = subscriber.subscription_path(PROJECT_ID, SUBSCRIPTION_ID)

    push_config = pubsub_v1.types.PushConfig(push_endpoint=PUSH_ENDPOINT)

    subscription = subscriber.create_subscription(
        request={
            "name": subscription_path,
            "topic": topic_name,
            "push_config": push_config,
            "ack_deadline_seconds": 60,
        }
    )
    print(f"Created push subscription: {subscription.name}")
    print(f"Push endpoint: {PUSH_ENDPOINT}")


def configure_gcs_notifications(topic_name: str) -> None:
    storage_client = storage.Client(project=PROJECT_ID)
    bucket = storage_client.bucket(BUCKET_NAME)

    notification = bucket.notification(
        topic_name=topic_name,
        event_types=["OBJECT_FINALIZE"],
        payload_format="JSON_API_V1",
    )
    notification.create()
    print(f"GCS notification configured on bucket '{BUCKET_NAME}' -> topic '{topic_name}'")


def main():
    topic_name = create_topic()
    create_push_subscription(topic_name)
    configure_gcs_notifications(topic_name)
    print("Setup complete.")


if __name__ == "__main__":
    main()
