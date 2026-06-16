import os

import firebase_admin
from firebase_admin import auth, credentials, firestore


DEMO_USERS = [
    {
        'username': 'Bijal M',
        'email': '02bijal@gmail.com',
        'password': 'Shoplens123!',
        'dob': '2000-03-14',
        'ignore_terms': ['cilantro'],
        'preference_terms': ['mug', 'apron'],
    },
    {
        'username': 'Surya R',
        'email': 'suryarao.r@gmail.com',
        'password': 'Shoplens123!',
        'dob': '1978-11-02',
        'ignore_terms': ['mushroom'],
        'preference_terms': ['garlic', 'pan'],
    },
    {
        'username': 'Lakshman S',
        'email': 'lsakarayinfo@gmail.com',
        'password': 'Shoplens123!',
        'dob': '1970-07-23',
        'ignore_terms': ['peanut'],
        'preference_terms': ['pot', 'basil'],
    },
    {
        'username': 'Prabha E',
        'email': 'eprabha2019@gmail.com',
        'password': 'Shoplens123!',
        'dob': '1980-09-08',
        'ignore_terms': ['onion'],
        'preference_terms': ['cutting board', 'knife'],
    },
]

DEFAULT_PROJECT_ID = '82592393149'


def initialize_app() -> firebase_admin.App:
    if firebase_admin._apps:
        return firebase_admin.get_app()

    project_id = (
        os.environ.get('FIREBASE_PROJECT_ID')
        or os.environ.get('FIRESTORE_PROJECT_ID')
        or os.environ.get('GOOGLE_CLOUD_PROJECT')
        or os.environ.get('GCLOUD_PROJECT')
        or os.environ.get('PROJECT_ID')
        or DEFAULT_PROJECT_ID
    )
    options = {'projectId': project_id} if project_id else {}
    cred_path = os.environ.get('GOOGLE_APPLICATION_CREDENTIALS')

    if cred_path:
        return firebase_admin.initialize_app(credentials.Certificate(cred_path), options=options)

    return firebase_admin.initialize_app(options=options)


def seed_users() -> None:
    initialize_app()
    db = firestore.client()

    for user in DEMO_USERS:
        try:
            record = auth.get_user_by_email(user['email'])
            auth.update_user(
                record.uid,
                display_name=user['username'],
                password=user['password'],
                email_verified=True,
            )
        except auth.UserNotFoundError:
            record = auth.create_user(
                email=user['email'],
                password=user['password'],
                display_name=user['username'],
                email_verified=True,
            )

        db.collection('UserProfiles').document(record.uid).set(
            {
                'username': user['username'],
                'dob': user['dob'],
                'ignore_terms': user['ignore_terms'],
                'preference_terms': user['preference_terms'],
            },
            merge=True,
        )

        print(f"Seeded {user['email']} -> {record.uid}")


if __name__ == '__main__':
    seed_users()
