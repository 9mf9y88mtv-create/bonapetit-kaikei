import json
import base64
import io
import pdfplumber

COLS = [('name', 160), ('cat1', 220), ('cat2', 290), ('price', 350), ('qty', 410), ('sales', 480)]

def bucket(x):
    for key, maxx in COLS:
        if x < maxx:
            return key
    return None

def parse_yen(s):
    s = (s or '').replace('¥', '').replace('￥', '').replace(',', '').strip()
    if s.lstrip('-').isdigit():
        return int(s)
    return 0

def extract_products(pdf_bytes):
    products = []
    with pdfplumber.open(io.BytesIO(pdf_bytes)) as pdf:
        for page in pdf.pages:
            words = page.extract_words()
            items = [{'str': w['text'], 'x': w['x0'], 'y': w['top']} for w in words]
            items.sort(key=lambda w: (w['y'], w['x']))
            lines = []
            cur = None
            for it in items:
                if cur is None or abs(cur['y'] - it['y']) > 2.5:
                    cur = {'y': it['y'], 'words': []}
                    lines.append(cur)
                cur['words'].append(it)
            main_lines = []
            for line in lines:
                has_name = any(w['x'] < 160 for w in line['words'])
                if has_name or not main_lines:
                    main_lines.append(line)
                else:
                    main_lines[-1]['words'].extend(line['words'])
            for line in main_lines:
                col = {'name': '', 'cat1': '', 'cat2': '', 'price': '', 'qty': '', 'sales': ''}
                for w in line['words']:
                    key = bucket(w['x'])
                    if key:
                        col[key] += w['str']
                name = col['name'].strip()
                if not name or name == '商品名' or 'Powered' in name:
                    continue
                qty = int(''.join(c for c in col['qty'] if c.isdigit()) or 0)
                sales = parse_yen(col['sales'])
                price = parse_yen(col['price'])
                if qty == 0 and sales == 0:
                    continue
                products.append({
                    'name': name, 'category1': col['cat1'].strip(), 'category2': col['cat2'].strip(),
                    'unitPrice': price, 'qty': qty, 'sales': sales
                })
    return products

def handler(event, context):
    headers = {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type',
        'Access-Control-Allow-Methods': 'POST, OPTIONS'
    }
    if event.get('httpMethod') == 'OPTIONS':
        return {'statusCode': 200, 'headers': headers, 'body': ''}
    try:
        body = event.get('body', '') or ''
        if event.get('isBase64Encoded'):
            raw = base64.b64decode(body)
        else:
            data = json.loads(body)
            raw = base64.b64decode(data['pdfBase64'])
        products = extract_products(raw)
        if not products:
            return {'statusCode': 200, 'headers': headers,
                    'body': json.dumps({'error': 'PDFから商品データを読み取れませんでした（サーバー側）'})}
        return {'statusCode': 200, 'headers': headers, 'body': json.dumps({'products': products})}
    except Exception as e:
        return {'statusCode': 500, 'headers': headers, 'body': json.dumps({'error': str(e)})}
