from PIL import Image
import pytesseract
import subprocess
import ollama

CONTEXT_PATH = "context.txt"
SCREENSHOT_PATH = "screen.png"
VM_PATH = "/home/linus/Qemu/bot"
LLM_MODEL = "llama3"
BOT_NAME = "bot"
VM_WAIT = 0.2
VNC_PORT = ":1"

get_stream = lambda message: ollama.chat(model=BOT_NAME, messages=[{'role': 'user', 'content': message}], stream=True)
vnc_type = lambda text: subprocess.run(["vncdo", "-s", VNC_PORT, "type", text])
vnc_key = lambda key: subprocess.run(["vncdo", "-s", VNC_PORT, "key", key])

def read_text():
    subprocess.run(["vncdo", "-s", VNC_PORT, "capture", SCREENSHOT_PATH])
    img = Image.open(SCREENSHOT_PATH)
    return pytesseract.image_to_string(img)

if __name__ == "__main__":
    try:
        qemu = subprocess.Popen([
            "qemu-system-x86_64",
            "-drive",
            f"file={VM_PATH},format=raw",
            "-vnc",
            VNC_PORT,
            "-m",
            "8G",
            "-smp",
            "8",
            "-enable-kvm",
            "-netdev",
            "user,id=n0",
            "-device",
            "e1000,netdev=n0",
        ])

        # subprocess.Popen(["feh", "--reload", "1", SCREENSHOT_PATH], start_new_session=True)

        with open(CONTEXT_PATH, "r") as f:
            llm = ollama.create(BOT_NAME, from_=LLM_MODEL, system=f.read())

        while True:
            match input("\n> "):
                case "":
                    read_text()
                case "run":
                    prompt = "<eye>" + read_text() + "</eye>"
                    print(prompt)
                    
                    out = []
                    for token in get_stream(prompt):
                        out.append(token.message.content)
                        print(token.message.content, end='', flush=True)
                    out = "".join(out)
                    
                    while "<keyboard>" in out and "</keyboard>" in out: 
                        start = out.find("<keyboard>") + len("<keyboard>")
                        end = out.find("</keyboard")
                        words = out[start:end].split('\\n')
                        vnc_type(words[0])
                        if len(words) > 1:
                            for word in words[1:]:
                                vnc_type(word)
                                vnc_key("enter")
                        
                        out = out[end + len("</keyboard>"):]
                case _:
                    print("unknown command")
    except Exception as e:
        qemu.kill()
        raise e
