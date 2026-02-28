from __future__ import print_function
import json
import os.path
import time
from urllib.parse import parse_qs, urlparse
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from google_auth_oauthlib.flow import InstalledAppFlow
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials

# Scopes pour l'API Gmail
SCOPES = ['https://www.googleapis.com/auth/gmail.labels', 'https://www.googleapis.com/auth/gmail.modify']
CREDENTIALS_FILE = 'credentials.json'
REQUIRED_OAUTH_KEYS = {'client_id', 'auth_uri', 'token_uri'}
RULES = [
    {
        'label': '📌 Administratif',
        'query': (
            'in:inbox '
            '(from:banquepostale.fr OR from:floa.fr OR '
            'subject:(solde OR releve OR relevé OR securite OR sécurité OR facture))'
        ),
        'archive': False,
    },
    {
        'label': '🔎 Alertes Emploi',
        'query': 'in:inbox (from:linkedin.com OR from:hellowork.com OR from:collective.work)',
        'archive': True,
    },
    {
        'label': '💼 Recrutement',
        'query': (
            'in:inbox '
            'subject:(recrutement OR candidature OR entretien OR mission) '
            '-label:"🔎 Alertes Emploi"'
        ),
        'archive': False,
    },
    {
        'label': '🛒 Commandes',
        'query': (
            'in:inbox '
            '(from:amazon.fr OR from:amazon.com OR from:uber.com OR from:cdiscount.com OR '
            'subject:(commande OR livraison OR expedi OR expédi))'
        ),
        'archive': True,
    },
    {
        'label': '📺 Streaming/Loisirs',
        'query': 'in:inbox (from:twitch.tv OR subject:(live OR stream))',
        'archive': True,
    },
    {
        'label': '📰 Newsletters',
        'query': 'in:inbox category:promotions',
        'archive': True,
    },
    {
        'label': '🔧 Alertes Techniques',
        'query': 'in:inbox (from:netdata.cloud OR subject:webinar)',
        'archive': False,
    },
    {
        'label': '📅 À Traiter',
        'query': (
            'in:inbox is:unread '
            '-category:promotions -category:social '
            '-label:"📰 Newsletters" -label:"🛒 Commandes" '
            '-label:"📺 Streaming/Loisirs" -label:"🔎 Alertes Emploi"'
        ),
        'archive': False,
    },
]


def load_client_config():
    with open(CREDENTIALS_FILE, 'r', encoding='utf-8') as credentials_file:
        config = json.load(credentials_file)

    if 'installed' in config:
        client_type = 'installed'
    elif 'web' in config:
        client_type = 'web'
    else:
        raise ValueError(
            "credentials.json doit contenir une section 'installed' ou 'web'."
        )

    client_config = config[client_type]
    missing_keys = REQUIRED_OAUTH_KEYS - set(client_config.keys())
    if missing_keys:
        raise ValueError(
            "credentials.json est incomplet. Clés manquantes: "
            + ", ".join(sorted(missing_keys))
        )

    redirect_uris = client_config.get('redirect_uris', [])
    if not redirect_uris:
        raise ValueError(
            "credentials.json doit contenir au moins une redirect_uri."
        )

    return config, client_type, client_config


def authorize_without_local_server(client_config_data, redirect_uri):
    flow = InstalledAppFlow.from_client_config(client_config_data, SCOPES)
    flow.redirect_uri = redirect_uri
    auth_url, _ = flow.authorization_url(access_type='offline')

    print("Impossible de démarrer le serveur OAuth local.")
    print("Ouvrez cette URL dans votre navigateur, puis copiez l'URL complète de redirection affichée dans la barre d'adresse :")
    print(auth_url)
    authorization_response = input("URL de redirection: ").strip()

    parsed = urlparse(authorization_response)
    if parsed.scheme and parsed.netloc:
        normalized_response = authorization_response
        if normalized_response.startswith('http://'):
            normalized_response = normalized_response.replace('http://', 'https://', 1)
        flow.fetch_token(authorization_response=normalized_response)
    else:
        code = parse_qs(parsed.query).get('code', [authorization_response])[0]
        flow.fetch_token(code=code)

    return flow.credentials

def get_gmail_service():
    creds = None
    client_config_data, _, client_config = load_client_config()
    # Le fichier token.json stocke les informations d'authentification de l'utilisateur
    if os.path.exists('token.json'):
        creds = Credentials.from_authorized_user_file('token.json', SCOPES)
    # Si les informations d'authentification ne sont pas valides ou n'existent pas, on les demande
    if not creds or not creds.valid:
        if creds and creds.expired and creds.refresh_token:
            creds.refresh(Request())
        else:
            flow = InstalledAppFlow.from_client_config(client_config_data, SCOPES)
            try:
                creds = flow.run_local_server(port=0, open_browser=False)
            except PermissionError:
                creds = authorize_without_local_server(
                    client_config_data,
                    client_config['redirect_uris'][0]
                )
        # Sauvegarde les informations d'authentification pour la prochaine fois
        with open('token.json', 'w') as token:
            token.write(creds.to_json())
    service = build('gmail', 'v1', credentials=creds)
    return service

def create_label_if_not_exists(service, label_name):
    results = service.users().labels().list(userId='me').execute()
    labels = results.get('labels', [])
    for label in labels:
        if label['name'] == label_name:
            return label['id']
    new_label = {'name': label_name, 'labelListVisibility': 'labelShow', 'messageListVisibility': 'show'}
    created_label = service.users().labels().create(userId='me', body=new_label).execute()
    return created_label['id']


def apply_rule(service, rule, label_id):
    label_name = rule['label']
    query = rule['query']
    remove_label_ids = ['INBOX'] if rule.get('archive') else []
    total_messages = 0
    page_token = None
    while True:
        results = service.users().messages().list(
            userId='me',
            q=query,
            pageToken=page_token,
            maxResults=500
        ).execute()
        messages = results.get('messages', [])
        if messages:
            message_ids = [message['id'] for message in messages]
            for index in range(0, len(message_ids), 1000):
                chunk = message_ids[index:index + 1000]
                retry_delay = 1
                while True:
                    try:
                        service.users().messages().batchModify(
                            userId='me',
                            body={
                                'ids': chunk,
                                'addLabelIds': [label_id],
                                'removeLabelIds': remove_label_ids,
                            }
                        ).execute()
                        break
                    except HttpError as error:
                        if error.resp.status not in (429, 500, 503) or retry_delay > 16:
                            raise
                        print(
                            f"[{label_name}] quota atteinte, nouvelle tentative dans {retry_delay}s"
                        )
                        time.sleep(retry_delay)
                        retry_delay *= 2

                total_messages += len(chunk)
                print(f"[{label_name}] {total_messages} messages traités")

        page_token = results.get('nextPageToken')
        if not page_token:
            break

    if total_messages == 0:
        print(f"[{label_name}] aucun message correspondant")
    else:
        action = 'archivés' if remove_label_ids else 'classés'
        print(f"[{label_name}] terminé: {total_messages} messages {action}")

def main():
    service = get_gmail_service()
    for rule in RULES:
        label_id = create_label_if_not_exists(service, rule['label'])
        apply_rule(service, rule, label_id)

    print("Tri des emails terminé.")

if __name__ == '__main__':
    main()
