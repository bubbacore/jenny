# Changelog

## [0.25.0](https://github.com/bubbacore/jenny/compare/v0.24.0...v0.25.0) (2026-10-27)


### ⚠ BREAKING CHANGES

* **db:** the current cinema identifier is now cinemark-jardins. Collection clients must use the identifier returned by the current plan. The website preserves previous URLs and selections.

### Bug Fixes

* **db:** shorten the Cinemark Jardins slug ([8f379f3](https://github.com/bubbacore/jenny/commit/8f379f383d10bcb98a0b88966aacfde2fc6af148))

## [0.24.0](https://github.com/bubbacore/jenny/compare/v0.23.1...v0.24.0) (2026-10-27)


### Features

* **db:** expose previous cinema slugs ([0074375](https://github.com/bubbacore/jenny/commit/0074375b6b9836f214604092874f81404a5a783c))

## [0.23.1](https://github.com/bubbacore/jenny/compare/v0.23.0...v0.23.1) (2026-10-27)


### Bug Fixes

* **db:** align cinema popular names ([333e183](https://github.com/bubbacore/jenny/commit/333e1832663a674c67dc0f3f2ada24f5ee2cbc26))

## [0.23.0](https://github.com/bubbacore/jenny/compare/v0.22.0...v0.23.0) (2026-10-24)


### Features

* **db:** read source apostrophe marks as an apostrophe ([f9db72b](https://github.com/bubbacore/jenny/commit/f9db72b58fffaebfaf48f7beeac7554b146700f1))


### Bug Fixes

* **ingestion:** read apostrophe marks as one in repeated sessions ([9b69689](https://github.com/bubbacore/jenny/commit/9b69689859ce6e6ac76a4f80023014b8a9856d12))

## [0.22.0](https://github.com/bubbacore/jenny/compare/v0.21.0...v0.22.0) (2026-10-23)


### Features

* **ingestion:** link a movie without TMDB to a TMDB movie ([2ed668c](https://github.com/bubbacore/jenny/commit/2ed668c959f31fd59953fcda83a16d4d9136d08c))
* **ingestion:** record the source poster of movies without TMDB ([4faed4e](https://github.com/bubbacore/jenny/commit/4faed4e6176eb11ab642a7678a6528c1da0e4a11))

## [0.21.0](https://github.com/bubbacore/jenny/compare/v0.20.0...v0.21.0) (2026-10-23)


### Features

* **db:** record movies without TMDB in the catalog ([a4f9f13](https://github.com/bubbacore/jenny/commit/a4f9f134bfd3957729387a4143870e0508eaaba4))
* **ingestion:** accept movies without TMDB in the reading ([02494c5](https://github.com/bubbacore/jenny/commit/02494c55965791b7c65db5626f35c0d82410486c))

## [0.20.0](https://github.com/bubbacore/jenny/compare/v0.19.0...v0.20.0) (2026-10-21)


### Features

* **ingestion:** record Certified Fresh with the Tomatometer ([dbc694f](https://github.com/bubbacore/jenny/commit/dbc694f416904b0f3b0fb04446ef5e84d4ffce8d))

## [0.19.0](https://github.com/bubbacore/jenny/compare/v0.18.0...v0.19.0) (2026-10-19)


### Features

* **ingestion:** update the ratings in every collection ([12387f9](https://github.com/bubbacore/jenny/commit/12387f9387de3579d6eec50f4da03420a2eacdff))

## [0.18.0](https://github.com/bubbacore/jenny/compare/v0.17.0...v0.18.0) (2026-10-16)


### ⚠ BREAKING CHANGES

* **db:** a reading with a session without a format and a 2D session with the same TMDB movie, start, room and audio is now refused as a repeated session, and sessions.format is not null.

### Features

* **db:** record sessions without a format as 2D ([9ad3033](https://github.com/bubbacore/jenny/commit/9ad3033e0987928602f1e300293e8321497f7ada))

## [0.17.0](https://github.com/bubbacore/jenny/compare/v0.16.1...v0.17.0) (2026-10-16)


### ⚠ BREAKING CHANGES

* **db:** a failed reading by error, incomplete reading or retained reading no longer erases the cinema's showtimes nor shows the cinema as updating.

### Features

* **db:** keep the showtimes after a failed reading ([22cc403](https://github.com/bubbacore/jenny/commit/22cc40306e088e82c484c30f97555ff334e10361))

## [0.16.1](https://github.com/bubbacore/jenny/compare/v0.16.0...v0.16.1) (2026-10-09)


### Bug Fixes

* **ingestion:** recollect cinemas without a finished reading ([0f16806](https://github.com/bubbacore/jenny/commit/0f1680600ceb52d8db2bed7582a0c6f767fdbc89))

## [0.16.0](https://github.com/bubbacore/jenny/compare/v0.15.0...v0.16.0) (2026-10-07)


### Features

* **ingestion:** name the proposed movie and publish released sessions ([f5688bf](https://github.com/bubbacore/jenny/commit/f5688bfc218ce62a535efff399ba4687458a163f))

## [0.15.0](https://github.com/bubbacore/jenny/compare/v0.14.0...v0.15.0) (2026-10-07)


### Features

* **ingestion:** accept the Google rating without the number of reviews ([d1fbf87](https://github.com/bubbacore/jenny/commit/d1fbf871eb5c3c1598ec663c8c288c863e8a67a4))

## [0.14.0](https://github.com/bubbacore/jenny/compare/v0.13.0...v0.14.0) (2026-10-06)


### Features

* **ingestion:** reimport the catalog and keep what vanished from TMDB ([90504e9](https://github.com/bubbacore/jenny/commit/90504e9b8c6092581e675ceaaff10f88d325a239))

## [0.13.0](https://github.com/bubbacore/jenny/compare/v0.12.1...v0.13.0) (2026-10-06)


### Features

* **ingestion:** update the cinema and decide the proposal ([8fe8c56](https://github.com/bubbacore/jenny/commit/8fe8c562225eeb7bfb4ababb7fe894407948af15))
* **ingestion:** update the movie ratings ([61c2eaa](https://github.com/bubbacore/jenny/commit/61c2eaadb3939640630bf88845f6d1d1fb9b4e81))

## [0.12.1](https://github.com/bubbacore/jenny/compare/v0.12.0...v0.12.1) (2026-10-06)


### Bug Fixes

* **ingestion:** repeat the pending identification alert each day ([7412e26](https://github.com/bubbacore/jenny/commit/7412e26a1e1b1b13e35815f374c6ddcd03667aef))

## [0.12.0](https://github.com/bubbacore/jenny/compare/v0.11.0...v0.12.0) (2026-10-06)


### Features

* **ingestion:** compare the session drop within the window ([ad08ca4](https://github.com/bubbacore/jenny/commit/ad08ca4455301f05cefdb527bc7b1cb376817a83))

## [0.11.0](https://github.com/bubbacore/jenny/compare/v0.10.1...v0.11.0) (2026-10-05)


### ⚠ BREAKING CHANGES

* **ingestion:** a post in the reading must carry its period, with a last day not before the first.

### Features

* **ingestion:** keep the post period and tell no sessions days ([d06ad65](https://github.com/bubbacore/jenny/commit/d06ad6596539e1d8787469b228874eeff9c2b624))

## [0.10.1](https://github.com/bubbacore/jenny/compare/v0.10.0...v0.10.1) (2026-10-05)


### Bug Fixes

* **db:** open the Cinema do Centro on Tuesdays ([8f09b16](https://github.com/bubbacore/jenny/commit/8f09b169fd4eb1b123adecf67c53b94b5be18835))

## [0.10.0](https://github.com/bubbacore/jenny/compare/v0.9.0...v0.10.0) (2026-10-05)


### ⚠ BREAKING CHANGES

* **catalog:** the movie slug comes from the original title instead of the title in Brazil, and existing slugs are rewritten.

### Features

* **catalog:** derive the movie address from the original title ([fc190ec](https://github.com/bubbacore/jenny/commit/fc190ecf795365786436f1487bc0e989cf447a9a))

## [0.9.0](https://github.com/bubbacore/jenny/compare/v0.8.0...v0.9.0) (2026-10-05)


### ⚠ BREAKING CHANGES

* **ingestion:** an ok reading of the official site must carry post or no_new_post, and only it may carry them.

### Features

* **ingestion:** remember read posts and reuse them without a new post ([89e05f1](https://github.com/bubbacore/jenny/commit/89e05f1983ce600980106004cbc317e5d023466b))

## [0.8.0](https://github.com/bubbacore/jenny/compare/v0.7.0...v0.8.0) (2026-10-05)


### Features

* **ingestion:** keep pending ticket types and resolve them ([2b59973](https://github.com/bubbacore/jenny/commit/2b5997389aae7849d22e6753d3d8790628796748))

## [0.7.0](https://github.com/bubbacore/jenny/compare/v0.6.0...v0.7.0) (2026-10-05)


### Features

* **ingestion:** choose movie values by source reliability ([55d9967](https://github.com/bubbacore/jenny/commit/55d99674f3317605587a907e20c99e6312829735))

## [0.6.0](https://github.com/bubbacore/jenny/compare/v0.5.0...v0.6.0) (2026-10-05)


### Features

* **ingestion:** add the catalog with people, credits, images and trailer ([9dc694d](https://github.com/bubbacore/jenny/commit/9dc694dd70c0f5940e7f89dba0bef0aedad282ca))

## [0.5.0](https://github.com/bubbacore/jenny/compare/v0.4.0...v0.5.0) (2026-10-03)


### Features

* **ingestion:** add pending identification and its resolution ([e569574](https://github.com/bubbacore/jenny/commit/e5695748d83e198664460d5d260489e0eddaf05f))

## [0.4.0](https://github.com/bubbacore/jenny/compare/v0.3.0...v0.4.0) (2026-10-03)


### ⚠ BREAKING CHANGES

* **ingestion:** start-reading requires collection_id, and collection-plan refuses chosen cinemas in a daily collection and requires them in a recollection.

### Features

* **ingestion:** add collections, automatic publication and summaries ([be8327b](https://github.com/bubbacore/jenny/commit/be8327b47ab5fddedd2f61a19024ef4c893a1d62))

## [0.3.0](https://github.com/bubbacore/jenny/compare/v0.2.0...v0.3.0) (2026-10-02)


### Features

* **ingestion:** record failed readings and the state of each day ([021e992](https://github.com/bubbacore/jenny/commit/021e99271f354b5b895c484ca29dc91af0619ae2))

## [0.2.0](https://github.com/bubbacore/jenny/compare/v0.1.0...v0.2.0) (2026-10-02)


### Features

* **ingestion:** publish the reading contract ([9651c54](https://github.com/bubbacore/jenny/commit/9651c54bb4ef1b5c6fffdcb92a84a537cd28e688))
* **ingestion:** reserve a cinema and record a successful reading ([5976922](https://github.com/bubbacore/jenny/commit/5976922f85b5a6a15f8936d4a5798e6a364855d1))
* **ingestion:** reserve a cinema and record a successful reading ([8ee7d1f](https://github.com/bubbacore/jenny/commit/8ee7d1f7d0f9a64a28d9337dd3d801543b4e430a))

## 0.1.0 (2026-10-02)


### Features

* add the v1 registry, closed database and collection plan ([0aedb12](https://github.com/bubbacore/jenny/commit/0aedb12f791c6073ca42f7b374ea873d148f19e4))
* **db:** add addresses, Instagram and sites of the v1 cinemas ([1f46476](https://github.com/bubbacore/jenny/commit/1f46476daf154c3e45f90573ac5cd9c1360e8f8f))
* **db:** add cities, chains, cinemas and sources ([08943d0](https://github.com/bubbacore/jenny/commit/08943d0a0109575199159eb66267c2deaa430a7f))
* **db:** add contact details and names of the v1 cinemas ([d8dfc8a](https://github.com/bubbacore/jenny/commit/d8dfc8a5569bf60d538af240d21422fdd2b957a0))
* **db:** add popular and official cinema names ([a23b92b](https://github.com/bubbacore/jenny/commit/a23b92b277e60553ee44958fedbd6f5be033d1a5))
* **db:** add the v1 registry ([846e8cb](https://github.com/bubbacore/jenny/commit/846e8cbab8e0af36c7989926d2faabaf37e66704))
* **db:** close the database to public reads ([ed47ec3](https://github.com/bubbacore/jenny/commit/ed47ec3b60c74221fb8d47cfca47e41e69a5176d))
* **ingestion:** serve the collection plan to the Hermes ([847407e](https://github.com/bubbacore/jenny/commit/847407e6a28dea774cc754f7e29b5d0d9dca5357))
