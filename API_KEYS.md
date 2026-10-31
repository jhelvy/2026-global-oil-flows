# API keys

Paste each key into `.env` in this folder, right after the `=` on its line. The placeholders are already there, and `.env` is ignored by git.

| Order | Variable in `.env` | Where to get it | Steps | Needed? |
|---|---|---|---|---|
| 1 | `COMTRADE_API_KEY` | https://comtradedeveloper.un.org/ | Sign up, open Products, subscribe to the free `comtrade - v1` product, then copy the primary key from your Profile page. | Most useful. It supplies the bilateral trade baseline. Without it, each call is capped at 500 rows. |
| 2 | `EIA_API_KEY` | https://www.eia.gov/opendata/register.php | Enter your name and email. The key arrives by email. | Helpful. It gives fresher daily Brent and targeted STEO queries. The bulk files work without it. |
| 3 | `FRED_API_KEY` | https://fredaccount.stlouisfed.org/apikeys | Sign in or create an account, then choose "Request API Key". | Optional. The FRED CSV download already works without it. |

The pipeline runs without these keys and uses them once they are present.
