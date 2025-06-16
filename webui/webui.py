from flask import Flask, render_template_string, request, redirect, url_for, flash
import os
import subprocess

app = Flask(__name__)
app.secret_key = 'arch-local-repo'

TARGET = os.path.expanduser(os.path.join('~', 'arch-mirror-repo'))
AUR_PACKAGES_FILE = os.path.join(TARGET, 'aur-packages.list')
SCRIPT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
SYNC_SCRIPT = os.path.join(SCRIPT_ROOT, 'sync-aur-local.sh')

INDEX_HTML = """
<!doctype html>
<title>Local AUR Repository</title>
<h1>Local AUR Packages</h1>
<form method="get" action="/">
    <input type="text" name="q" placeholder="Search" value="{{ query }}">
    <button type="submit">Search</button>
</form>
<ul>
{% for pkg in packages %}
<li>{{ pkg }}
    <form style="display:inline" method="post" action="{{ url_for('remove_package') }}">
        <input type="hidden" name="name" value="{{ pkg }}">
        <button type="submit">Remove</button>
    </form>
    <form style="display:inline" method="post" action="{{ url_for('build_package') }}">
        <input type="hidden" name="name" value="{{ pkg }}">
        <button type="submit">Build</button>
    </form>
</li>
{% endfor %}
</ul>
<h2>Add Package</h2>
<form method="post" action="{{ url_for('add_package') }}">
    <input name="name">
    <button type="submit">Add</button>
</form>
{% with messages = get_flashed_messages() %}
  {% if messages %}
    <ul>
    {% for m in messages %}
      <li>{{ m }}</li>
    {% endfor %}
    </ul>
  {% endif %}
{% endwith %}
"""

def load_packages():
    if not os.path.exists(AUR_PACKAGES_FILE):
        return []
    with open(AUR_PACKAGES_FILE) as f:
        return [line.strip() for line in f if line.strip() and not line.startswith('#')]

def save_packages(pkgs):
    os.makedirs(os.path.dirname(AUR_PACKAGES_FILE), exist_ok=True)
    with open(AUR_PACKAGES_FILE, 'w') as f:
        for p in pkgs:
            f.write(p + '\n')

def run_sync(pkg=None):
    cmd = [SYNC_SCRIPT, '-S']
    if pkg:
        cmd.append(pkg)
    subprocess.Popen(cmd)

@app.route('/')
def index():
    query = request.args.get('q', '').strip()
    pkgs = load_packages()
    if query:
        pkgs = [p for p in pkgs if query.lower() in p.lower()]
    return render_template_string(INDEX_HTML, packages=pkgs, query=query)

@app.route('/add', methods=['POST'])
def add_package():
    name = request.form.get('name', '').strip()
    if not name:
        flash('Package name required')
    else:
        pkgs = load_packages()
        if name not in pkgs:
            pkgs.append(name)
            save_packages(pkgs)
            flash(f'Added {name}')
        else:
            flash(f'{name} already exists')
    return redirect(url_for('index'))

@app.route('/remove', methods=['POST'])
def remove_package():
    name = request.form.get('name', '').strip()
    pkgs = load_packages()
    if name in pkgs:
        pkgs.remove(name)
        save_packages(pkgs)
        flash(f'Removed {name}')
    else:
        flash(f'{name} not found')
    return redirect(url_for('index'))

@app.route('/build', methods=['POST'])
def build_package():
    name = request.form.get('name', '').strip()
    run_sync(name if name else None)
    flash(f'Build started for {name or "all packages"}')
    return redirect(url_for('index'))

if __name__ == '__main__':
    app.run(debug=True)
