import requests
from urllib.parse import quote

# Configuration
WIKI_URL = "https://prod-climatekg.semanticclimate.org"
PAGE_TITLE = "IPCC:AR6/SR15/Chapter-1"

def fetch_wiki_page_html(wiki_url, page_title):
    """
    Fetch the HTML content of a wiki page using the MediaWiki API.
    
    Args:
        wiki_url: Base URL of the wiki (e.g., 'https://example.com')
        page_title: Title of the page to fetch (e.g., 'IPCC:AR6/WGIII/Chapter-9')
    
    Returns:
        str: HTML content of the page
    """
    # MediaWiki API endpoint
    api_url = f"{wiki_url}/w/api.php"
    
    # API parameters for parsing the page
    params = {
        'action': 'parse',
        'page': page_title,
        'format': 'json',
        'prop': 'text',  # Get the parsed HTML
        'disablelimitreport': True
    }
    
    try:
        # Make the API request
        response = requests.get(api_url, params=params, timeout=30)
        response.raise_for_status()
        
        # Parse JSON response
        data = response.json()
        
        if 'parse' in data and 'text' in data['parse']:
            html_content = data['parse']['text']['*']
            return html_content
        elif 'error' in data:
            raise Exception(f"API Error: {data['error']['info']}")
        else:
            raise Exception("Unexpected API response format")
            
    except requests.exceptions.RequestException as e:
        raise Exception(f"Request failed: {e}")

def save_html_to_file(html_content, filename='page.html'):
    """Save HTML content to a file."""
    with open(filename, 'w', encoding='utf-8') as f:
        f.write(html_content)
    print(f"HTML saved to {filename}")

if __name__ == "__main__":
    try:
        print(f"Fetching page: {PAGE_TITLE}")
        html = fetch_wiki_page_html(WIKI_URL, PAGE_TITLE)
        
        # Save to file
        output_file = "api/sr15-ch1.html"
        save_html_to_file(html, output_file)
        
        # Print first 500 characters as preview
        print(f"\nPreview (first 500 characters):")
        print(html[:500])
        
    except Exception as e:
        print(f"Error: {e}")
