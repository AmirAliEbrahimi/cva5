"""
train.py — train SmallCNN on two CIFAR-10 classes

Why CIFAR-10: already 32x32 (matches the swept architecture exactly), auto-
downloads, and classes 3 (cat) and 5 (dog) give 10,000 train / 2,000 test
images. Cat vs dog is the most-confused pair in CIFAR-10, so it is a real
benchmark rather than a toy.

IMPORTANT -- normalization: inputs are scaled to [0,1] with ToTensor() only,
NOT the usual mean/std normalization. Standard CIFAR normalization produces
values near +-2.7, which saturates any ap_fixed<N,2> config (range +-2) and
would look like a precision failure when it is actually a range failure.

The model definition here must stay byte-identical to the one in sweep.py and
evaluate.py and export_weights.py, or the state_dict will not load.

Usage:
    pip install torchvision
    python train.py                  # ~10 min CPU, downloads ~170MB
    python evaluate.py model_6_8.pt 6 8

VERIFIED: model construction and state_dict round-trip into evaluate.py's
SmallCNN were executed locally.
NOT VERIFIED: the training run itself (no CIFAR download available here).
"""

import argparse
import torch
import torch.nn as nn
import torch.optim as optim
from torch.utils.data import DataLoader, Subset
import torchvision
import torchvision.transforms as transforms
import numpy as np

NAMES = ["airplane", "automobile", "bird", "cat", "deer",
         "dog", "frog", "horse", "ship", "truck"]

CAT, DOG = 6, 8          # CIFAR-10 class indices: frog, ship
EPOCHS = 30
BATCH = 128
LR = 1e-3
OUT = "model_6_8.pt"


class SmallCNN(nn.Module):
    """Must match sweep.py, evaluate.py and export_weights.py exactly."""

    def __init__(self, n_classes=2):
        super().__init__()
        self.c1 = nn.Conv2d(3, 4, 3, padding=1)
        self.r1 = nn.ReLU()
        self.p1 = nn.MaxPool2d(4)
        self.c2 = nn.Conv2d(4, 8, 3, padding=1)
        self.r2 = nn.ReLU()
        self.p2 = nn.MaxPool2d(4)
        self.fl = nn.Flatten()
        self.fc = nn.Linear(8 * 2 * 2, n_classes)

    def forward(self, x):
        x = self.p1(self.r1(self.c1(x)))
        x = self.p2(self.r2(self.c2(x)))
        return self.fc(self.fl(x))


def cat_dog_subset(train):
    """CIFAR-10 filtered to cats and dogs, relabelled 0/1.

    ToTensor() alone -> [0,1]. Do not add Normalize(mean, std); see module
    docstring.
    """
    tf = [transforms.ToTensor()]
    if train:
        # Mild augmentation only. Heavy augmentation on a 4-filter network
        # mostly just slows convergence.
        tf = [transforms.RandomHorizontalFlip()] + tf

    ds = torchvision.datasets.CIFAR10(root="./data", train=train,
                                      download=True,
                                      transform=transforms.Compose(tf))
    targets = np.array(ds.targets)
    idx = np.where((targets == CAT) | (targets == DOG))[0]
    ds.targets = [0 if targets[i] == CAT else 1 for i in idx]
    sub = Subset(ds, idx)

    # Subset does not remap labels, so patch the underlying targets instead.
    full = np.array(ds.targets)
    remapped = np.zeros(len(ds.data), dtype=int)
    for pos, i in enumerate(idx):
        remapped[i] = full[pos]
    ds.targets = remapped.tolist()
    return sub


def evaluate(model, loader, device):
    model.eval()
    correct = total = 0
    with torch.no_grad():
        for x, y in loader:
            x, y = x.to(device), y.to(device)
            pred = model(x).argmax(1)
            correct += (pred == y).sum().item()
            total += y.size(0)
    return 100.0 * correct / total


def main():
    global CAT, DOG, OUT, EPOCHS
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--classes", nargs=2, type=int, default=[CAT, DOG],
                    metavar=("A", "B"), help="CIFAR-10 class indices")
    ap.add_argument("--out", default=None, help="output state_dict path")
    ap.add_argument("--epochs", type=int, default=EPOCHS)
    args = ap.parse_args()
    CAT, DOG = args.classes
    EPOCHS = args.epochs
    OUT = args.out or f"model_{CAT}_{DOG}.pt"
    print(f"{NAMES[CAT]} (label 0) vs {NAMES[DOG]} (label 1) -> {OUT}")

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Device: {device}")

    train_ds = cat_dog_subset(train=True)
    test_ds = cat_dog_subset(train=False)
    print(f"Train: {len(train_ds)}  Test: {len(test_ds)}")

    train_dl = DataLoader(train_ds, batch_size=BATCH, shuffle=True)
    test_dl = DataLoader(test_ds, batch_size=BATCH)

    model = SmallCNN().to(device)
    crit = nn.CrossEntropyLoss()
    opt = optim.Adam(model.parameters(), lr=LR)
    sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=EPOCHS)

    best = 0.0
    for epoch in range(EPOCHS):
        model.train()
        running = 0.0
        for x, y in train_dl:
            x, y = x.to(device), y.to(device)
            opt.zero_grad()
            loss = crit(model(x), y)
            loss.backward()
            opt.step()
            running += loss.item()
        sched.step()

        acc = evaluate(model, test_dl, device)
        flag = ""
        if acc > best:
            best = acc
            torch.save(model.state_dict(), OUT)
            flag = "  <- saved"
        print(f"epoch {epoch+1:2d}/{EPOCHS}  loss {running/len(train_dl):.4f}  "
              f"test {acc:.2f}%{flag}")

    print(f"""
Best test accuracy: {best:.2f}%   saved to {OUT}

That is this architecture's ceiling for {NAMES[CAT]} vs {NAMES[DOG]}, not a
training limit -- 474 parameters is what fits a 7020 alongside CVA5, and it is
the model the resource and latency numbers were measured against. Accuracy
varies a lot by class pair (pair_search.py screens all 45); widening the conv
layers would change every resource number and needs a fresh sweep.

Next:
    make -C tools/nn_accel precision      # or: python evaluate.py {OUT} {CAT} {DOG}

That measures the model's actual dynamic range and sweeps precision at the
integer width that range requires. Take the narrowest total width whose
accuracy stays within about 1% of float. Both range and resolution matter and
they fail differently -- see docs/nn_accelerator/GOTCHAS.md.
""")


if __name__ == "__main__":
    main()
