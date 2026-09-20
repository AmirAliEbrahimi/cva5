"""
pair_search.py — find the CIFAR-10 class pair this architecture handles best.

The architecture is fixed (474 parameters, the one the whole sweep
characterized), so every resource number you have stays valid no matter which
pair wins. Only the dataset changes.

All 45 pairs are screened with a short training run, then you fully train the
winner. Data is loaded into memory once and indexed per pair, rather than
rebuilding a DataLoader each time -- with a model this small, data handling
dominates otherwise.

Usage:
    python pair_search.py                 # screen all 45 pairs
    python pair_search.py --epochs 15     # more thorough screen
    python pair_search.py --final 1 8     # fully train one pair, save state_dict

VERIFIED: model, batching, and the train/eval loop were executed locally on
synthetic data of CIFAR's shape.
NOT VERIFIED: real CIFAR accuracies or wall-clock time (no download available
in my environment). Screening 45 pairs will likely take 1-3 hours on CPU.
"""

import argparse
import itertools
import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
import torchvision
import torchvision.transforms as transforms

NAMES = ["airplane", "automobile", "bird", "cat", "deer",
         "dog", "frog", "horse", "ship", "truck"]


class SmallCNN(nn.Module):
    """Identical to train.py / sweep.py / evaluate.py. Do not change -- the
    resource numbers in the sweep describe exactly this network."""

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


def load_cifar():
    """Whole dataset into memory once, [0,1] scaled to match train.py.

    Do NOT add mean/std normalization: it produces values near +-2.7, which
    saturates every ap_fixed<N,2> configuration in the sweep.
    """
    tf = transforms.ToTensor()
    out = {}
    for split, train in (("train", True), ("test", False)):
        ds = torchvision.datasets.CIFAR10(root="./data", train=train,
                                          download=True, transform=tf)
        X = torch.from_numpy(ds.data).permute(0, 3, 1, 2).float() / 255.0
        y = torch.tensor(ds.targets)
        out[split] = (X, y)
        print(f"  {split}: {tuple(X.shape)}")
    return out


def subset(X, y, a, b):
    mask = (y == a) | (y == b)
    return X[mask], (y[mask] == b).long()


def train_pair(data, a, b, epochs, device, seed=0, augment=True):
    torch.manual_seed(seed)
    Xtr, ytr = subset(*data["train"], a, b)
    Xte, yte = subset(*data["test"], a, b)
    Xtr, ytr = Xtr.to(device), ytr.to(device)
    Xte, yte = Xte.to(device), yte.to(device)

    model = SmallCNN().to(device)
    crit = nn.CrossEntropyLoss()
    opt = optim.Adam(model.parameters(), lr=2e-3)
    sched = optim.lr_scheduler.CosineAnnealingLR(opt, T_max=epochs)

    n, batch = len(Xtr), 128
    best, best_state = 0.0, None

    for _ in range(epochs):
        model.train()
        perm = torch.randperm(n, device=device)
        for i in range(0, n, batch):
            idx = perm[i:i + batch]
            xb, yb = Xtr[idx], ytr[idx]
            if augment:                      # random horizontal flip
                flip = torch.rand(len(xb), device=device) < 0.5
                xb = torch.where(flip[:, None, None, None], xb.flip(-1), xb)
            opt.zero_grad()
            crit(model(xb), yb).backward()
            opt.step()
        sched.step()

        model.eval()
        with torch.no_grad():
            acc = (model(Xte).argmax(1) == yte).float().mean().item() * 100
        if acc > best:
            best = acc
            best_state = {k: v.clone() for k, v in model.state_dict().items()}

    return best, best_state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=10,
                    help="epochs per pair during screening")
    ap.add_argument("--final", nargs=2, type=int, metavar=("A", "B"),
                    help="fully train one pair (60 epochs) and save it")
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Device: {device}\nLoading CIFAR-10...")
    data = load_cifar()

    if args.final:
        a, b = args.final
        print(f"\nFully training {NAMES[a]} vs {NAMES[b]} (60 epochs)...")
        acc, state = train_pair(data, a, b, 60, device)
        out = f"model_{NAMES[a]}_{NAMES[b]}.pt"
        torch.save(state, out)
        print(f"Best test accuracy: {acc:.2f}%\nSaved: {out}")
        print(f"\nNext:\n    python evaluate.py {out} {a} {b}")
        return

    pairs = list(itertools.combinations(range(10), 2))
    print(f"\nScreening {len(pairs)} pairs at {args.epochs} epochs each.\n")

    results = []
    for k, (a, b) in enumerate(pairs, 1):
        acc, _ = train_pair(data, a, b, args.epochs, device)
        results.append((acc, a, b))
        print(f"[{k:2d}/{len(pairs)}] {NAMES[a]:>10} vs {NAMES[b]:<10} "
              f"{acc:6.2f}%")

    results.sort(reverse=True)
    print("\n" + "=" * 52)
    print("TOP 10")
    print("=" * 52)
    for acc, a, b in results[:10]:
        print(f"  {acc:6.2f}%   {NAMES[a]:>10} vs {NAMES[b]}")
    print("\nBOTTOM 5 (hardest)")
    for acc, a, b in results[-5:]:
        print(f"  {acc:6.2f}%   {NAMES[a]:>10} vs {NAMES[b]}")

    acc, a, b = results[0]
    print(f"""
Screening used only {args.epochs} epochs, so these are rankings rather than
final accuracies -- a full run will add a few points.

Fully train the winner:
    python pair_search.py --final {a} {b}

Then the precision comparison, which is the number you actually need:
    make -C tools/nn_accel precision CLASS_A={a} CLASS_B={b}

Worth keeping the cat/dog result (67%) alongside whatever wins. "Hardest pair
67%, easiest pair {acc:.0f}%, identical hardware" shows the accelerator's cost
is independent of task difficulty -- which is the point when the contribution
is the integration, not the network.
""")


if __name__ == "__main__":
    main()
