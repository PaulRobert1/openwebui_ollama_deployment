TO INSTALL AND CONFIGURE RUN FOLLOWING IN TERMINAL:
________________________________________________________________________________
cd ~/Downloads
chmod +x deploy-local-ai-suite-v8.8.sh
./deploy-local-ai-suite-v8.8.sh
_________________________________________________________________________________




# Local AI Assistant Deployment

This project is my personal local AI assistant stack running entirely on my gaming PC.

The goal was fairly simple at the beginning: run a capable uncensored local model, give it internet access, let it remember useful information, make it useful for technical troubleshooting, and avoid waiting long enough for an answer that I have time to make coffee, forget why I made coffee, and return to find the model still thinking.

It eventually turned into a complete OpenWebUI based assistant platform with dedicated models for normal conversations, research, deep research, background processing, web search, persistent knowledge, document recall, and technical troubleshooting.

Everything runs locally on my own hardware.

## Hardware

The system is built around:

**CPU:** AMD Ryzen 7 9700X

**GPU:** AMD Radeon RX 9070 XT with 16 GB VRAM

**Memory:** 32 GB DDR5

**Storage:** 1 TB NVMe SSD

**Motherboard:** ASUS PRIME B850 PLUS WIFI

The RX 9070 XT provides the main inference acceleration through ROCm.

The primary 27B model is configured with a 32K context window and stays completely resident on the GPU.

In testing this resulted in approximately 13 GB model residency with 100 percent GPU processing and enough remaining VRAM for the context cache and normal desktop operation.

The lesson learned here was simple.

16 GB VRAM is a lot until you introduce a 27B model to it.

Then suddenly every megabyte has a job.

## Operating System

The machine runs Fedora KDE.

Fedora provides the host environment for Ollama, ROCm, Docker, OpenWebUI, SearXNG, and the rest of the local AI stack.

Ollama runs natively as a systemd service rather than inside Docker.

This allows direct access to the AMD GPU while OpenWebUI and SearXNG remain isolated inside containers.

## Architecture

The deployment consists of four major components.

**Ollama**

Runs directly on Fedora and handles model inference through the Radeon RX 9070 XT.

Ollama listens on port 11434 and is configured so the OpenWebUI Docker container can reach it through the Docker host gateway.

Flash Attention is enabled.

The KV cache uses q8 quantization.

Only one large model request is processed in parallel to avoid multiplying context memory requirements.

The default model remains loaded permanently so a new question does not trigger a full model reload.

**OpenWebUI**

Runs inside Docker and provides the main user interface.

OpenWebUI handles conversations, model selection, tools, knowledge retrieval, memory integration, document uploads, and web search.

Persistent application data is stored in a Docker volume so containers can be replaced or updated without losing chats, users, knowledge, memories, or configuration.

**SearXNG**

Runs as a separate Docker container.

It provides local metasearch for OpenWebUI and is configured with JSON output enabled.

OpenWebUI communicates directly with SearXNG through the internal Docker network.

This gives the local assistant internet search capability without depending on a commercial search API for every request.

**Persistent Knowledge and Memory**

Documents and durable information are handled separately.

Full documents belong in the persistent Knowledge system.

Compact information about those documents is stored in Memory.

This prevents entire manuals, PDFs, troubleshooting guides, and documentation collections from being injected into every conversation.

Instead, relevant information is retrieved only when the current topic matches it.

## Model Workflow

The deployment uses multiple models because asking a 27B model to generate chat titles is like starting a V8 engine to turn on a desk lamp.

### Natural Fast 27B

This is the default assistant.

It uses a 32K context window and remains completely GPU resident on the RX 9070 XT.

It is intended for everyday use including:

Technical troubleshooting

PowerShell

Windows

Linux

Citrix

FSLogix

OpenWebUI

Networking

Coding

Configuration analysis

General questions

Web assisted research

Knowledge retrieval

Normal conversations

This is the model I use most of the time.

Thinking is disabled by default to prevent unnecessary internal reasoning loops on simple requests.

The assistant is instructed to gather evidence before diagnosing technical problems.

If required information is missing, it should ask for logs, configuration, command output, screenshots, documentation, versions, or other relevant evidence rather than inventing a probable answer.

The objective is not to have an AI that sounds confident.

The objective is to have one that is correct.

Those are unfortunately not always the same thing.

## Research Plus 27B

This model uses a 64K context window.

It is intended for larger research sessions, longer conversations, bigger documentation sets, and heavier retrieval workloads.

The additional context comes with increased VRAM requirements, so some CPU offloading may occur depending on the workload.

It is therefore not used as the default model.

Use this when the question is larger than the Natural Fast model comfortably handles.

## Deep Research 27B

This model uses a 128K context window.

It is intended for very large investigations, multiple large documents, long technical research sessions, and situations where context capacity matters more than response speed.

Thinking can be enabled when deeper reasoning is actually required.

This is the model for situations where the phrase "quick question" has already become a lie.

## Background Scout 270M

This tiny model works behind the scenes.

It is not intended for normal conversations.

OpenWebUI uses it for background tasks such as:

Conversation titles

Tags

Search query generation

Retrieval query generation

Internal helper operations

Originally these jobs were performed by the main 27B model.

That created an interesting situation where the large model could spend thirty seconds doing invisible housekeeping before answering a two sentence question.

Moving these tasks to the tiny Background Scout model dramatically improved response latency.

The large model can now concentrate on being an AI assistant instead of deciding what to name the chat.

## Web Search

SearXNG provides the web search backend.

Search is integrated directly into OpenWebUI.

The assistant can search the internet when current or external information is required.

The system prompt instructs the assistant not to search unnecessarily.

The preferred information order is:

Current conversation evidence

Relevant stored memory

Relevant stored knowledge

Diagnostic information

Current vendor documentation

Web search

This reduces unnecessary searches and keeps common technical questions fast.

## Troubleshooting Philosophy

The assistant follows an evidence first workflow.

When troubleshooting a problem it should first determine what is already known.

It then checks relevant memory and available documentation.

If information is missing, it requests exactly what is required.

This can include logs, registry values, PowerShell output, event logs, configuration files, screenshots, software versions, network tests, or documentation.

Only after enough evidence exists should it determine a root cause.

The assistant is specifically instructed not to produce ten hypothetical causes simply because ten causes are theoretically possible.

If a command can prove which cause is responsible, the preferred response is to provide the command.

When possible, diagnostic commands are provided ready for direct copy and paste.

## Persistent Memory

Memory is enabled, but automatic injection of the entire memory database into every conversation is disabled.

This is intentional.

The assistant can search memory for information relevant to the current topic.

For example, a Citrix question should retrieve Citrix related information.

It should not also receive details about motorcycles, Home Assistant, gaming, printers, cameras, and everything else the assistant has ever learned.

Memory therefore acts as searchable long term context rather than an increasingly enormous system prompt.

Useful durable information can include:

Infrastructure architecture

Hardware

Operating systems

Application versions

Server roles

Network configuration

Known technical limitations

Previous confirmed troubleshooting results

Successful fixes

Recurring environment details

User preferences that affect future technical work

Passwords, tokens, API keys, and temporary conversational noise should never be stored.

## Persistent Document Memory

Uploaded documents use a dedicated workflow.

When a document is uploaded, the user is asked whether it should be remembered for future conversations.

If the answer is no, the document remains relevant only to the current conversation.

If the answer is yes, the document is added to persistent Knowledge.

A compact memory index is also created containing information such as the document title, subject, useful keywords, and its Knowledge reference.

Future conversations can then discover the document automatically when the user mentions related topics.

For example, a Citrix troubleshooting guide stored today can be recalled weeks later when a completely new conversation mentions VDA registration, BrokerAgent, HDX, or another relevant subject.

Only relevant excerpts are retrieved.

Unrelated documents remain outside the prompt.

This provides persistent document awareness without sacrificing the available model context window.

## Typo Handling and Response Discipline

The assistant is instructed to silently interpret obvious typing mistakes when the intended meaning is clear.

For example:

`ehat about citrix`

should simply be understood as:

`what about citrix`

There is no reason for a 27B parameter language model to hold a committee meeting over one mistyped letter.

The system also contains instructions designed to prevent reasoning loops and internal review text from leaking into normal responses.

The assistant should not repeatedly produce phrases such as:

"Okay"

"One final check"

"Looks good"

"Final answer"

or generate the same completed answer multiple times.

Normal responses should contain the answer, not the model reviewing itself reviewing itself reviewing itself.

## Performance Configuration

The main Natural Fast model currently runs with:

32K context

q8 KV cache

Flash Attention enabled

One parallel request

Permanent model residency

100 percent GPU processing

No CPU model offload

The RX 9070 XT is kept close to its VRAM capacity but still provides sufficient headroom for stable inference.

The larger Research Plus and Deep Research profiles intentionally trade speed and memory efficiency for additional context.

## Deployment Philosophy

The deployment script is designed to work both on the existing system and on a new Fedora machine.

On an existing installation it detects and preserves existing components whenever possible.

Models are reused rather than downloaded again.

Existing OpenWebUI chats, users, memories, knowledge, and configuration are preserved.

Existing SearXNG installations are preserved when healthy.

On a fresh system the deployment can configure the complete stack including Ollama, Docker, OpenWebUI, SearXNG, model profiles, task model configuration, memory settings, knowledge integration, and networking.

The deployment also performs connectivity checks between OpenWebUI and Ollama instead of simply assuming that because both services are running they can actually talk to each other.

That particular feature exists because experience is an excellent documentation generator.

## Final Stack

The finished system provides:

Local LLM inference

AMD GPU acceleration

OpenWebUI interface

SearXNG internet search

Dedicated background task model

32K default assistant context

64K research context

128K deep research context

Persistent memory

Persistent document knowledge

Cross conversation document recall

Evidence based troubleshooting

Automatic web research

Technical documentation retrieval

Copy ready diagnostic commands

No mandatory cloud AI dependency for normal operation

The end result is essentially a private technical assistant running on a gaming PC.

It can troubleshoot Citrix in one conversation, search documentation in another, remember a PDF uploaded weeks earlier, write PowerShell, investigate Linux, and still leave enough GPU performance available to remind me that I originally bought this machine for gaming.

At least that was the official story.
