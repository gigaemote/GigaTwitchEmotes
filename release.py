EMOTES_FILE="emotes.txt"

with open(EMOTES_FILE) as f:
    lines = f.readlines()

for line in lines:
    print(f"• {line.split('/')[-1].split('.')[0]}")
